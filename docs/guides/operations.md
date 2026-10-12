# Operations

Running a server that has real data in it.

## Backup and restore

`PDS_DATA_DIR` is the whole server: the database, the keys, the blobs and the
secret. Every verb has two spellings: `pesque <verb>`, the host CLI, which
stops and starts the service when a verb needs that, and `bin/pesque <verb>`
from the release directory. `mix pesque.<verb>` runs the same code in dev.

`pesque backup [--out DIR]` writes `pesque-backup-<stamp>.tar.gz` and is safe
to run while the server is up. The database is snapshotted with `VACUUM INTO`
first, so the archive holds the committed state at one instant; the keys, the
blobs, the secret and, when the server has minted one, `server.identity.json`
are read straight out of the data directory after. That is safe on a running
server because an upload writes the file before the row that serves it: the
worst a race with a running upload can do is put an orphan file in the
archive, never a row whose bytes are missing. The verb refuses a data
directory that is missing a piece every booted server has: an archive that
looks complete and restores into a server that cannot boot is worse than a
refused backup.

```bash
pesque backup --out /backups
```

Restore is cold. The host CLI stops the service before the verb runs and
starts it again after; running `bin/pesque restore` directly means stopping
the service yourself, and either way the verb refuses while another process
holds the database's write lock. The archive is extracted into a staging
directory inside the data directory and verified against its manifest before
anything moves, then swapped in one entry at a time: every current file moves
to `<name>.old` before its replacement takes its name, and the old database's
WAL sidecars move with it. A crash mid-swap leaves the previous state next to
the new one: rename the `.old` files back, or run restore again. A completed
swap removes them; the archive itself is the way back.

```bash
pesque restore /backups/pesque-backup-20261011T123456Z.tar.gz
```

Migrations run at boot, so restoring onto a newer binary is fine; a newer data
directory onto an older binary is not. The archive carries `server.secret`, so
treat it as you would the data directory: lose it and every legacy session
dies.

## The data directory

```
data/
├── pesque.db            SQLite: accounts, records, blocks, blobs, events, invites, preferences, OAuth state
├── server.secret        HMAC secret for legacy session tokens
├── server.identity.json the server's minted did:plc, only under identity = plc
├── keys/<digest>.key            secp256k1 signing key per DID
├── keys/<digest>.rotation.key   did:plc rotation key, the account's only recovery path
├── keys/oauth.p256.key          P-256 key OAuth tokens and the JWKS are signed with
├── blobs/<digest>/<cid> blob bytes, addressed by CID
└── lexicons/            lexicon overrides, if any
```

Key files are named after a SHA-256 digest of the DID, because a DID is not a
filename. Sensitivity, highest first:

| What | If it leaks |
| --- | --- |
| `server.secret` | Mint a valid legacy session for any account |
| `keys/oauth.p256.key` | Mint access tokens for any account |
| `keys/*.rotation.key` | Take over a did:plc identity |
| `keys/*.key` | Forge commits for one account |
| `pesque.db` | Emails, password hashes (Argon2), records, events |
| `blobs/` | Public by protocol |

Secrets are `0600` and `keys/` is `0700`; the data directory takes your umask.

## Account lifecycle

- `com.atproto.identity.updateHandle` moves a handle. A `did:plc` account may
  move to a foreign handle once it verifies; a `did:web` account stays under this
  server's domain.
- `com.atproto.server.deactivateAccount` / `activateAccount` stop and resume
  writes without touching the repo; a deactivated repo still answers
  `getRepoStatus`.
- `com.atproto.server.deleteAccount` is two-step: `requestAccountDelete` returns
  a token in the body (no email is sent), then `deleteAccount` spends it with the
  password. Rows, blocks, blobs and keys go; firehose events stay.
- `com.atproto.identity.requestPlcOperationSignature` /
  `signPlcOperation` move a hosted `did:plc` account out. The spec emails the
  code to the account holder; there is no mail here, so the code reaches the
  operator instead: it is logged when a client asks, and `pesque account
  plc-token --did D | --handle H` mints another on demand. It is good for 15
  minutes and single use; `signPlcOperation` spends it. The signed operation is
  the answer, not a submission: hand it to the client, which submits it to the
  PLC directory or to the PDS the account is moving to.
- `com.atproto.server.createInviteCodes` mints codes, operator-only (see below).

## Replace the legal pages

`describeServer` advertises `/privacy-policy.md` and `/terms-of-service.md` from
`priv/static/`. They ship as placeholders; replace them before pointing a real
domain at the server.

## Upgrades

The manual flow, spelled out once:

1. `pesque backup` (live-safe; no stop needed)
2. `bin/pesque stop` (clean `SIGTERM`)
3. Replace the release directory
4. `bin/pesque start`, migrations run at boot
5. `curl /xrpc/_health`, which reads a table, so it is the migration check

`pesque config validate` boots nothing: it reads the environment and
`pesque.conf` the way the server will at boot, then prints every resolved
setting with the layer that decided it, the environment variable,
`pesque.conf:LINE`, or `(default)`. Run it after replacing the release: an
unknown `PDS_*` variable or config key fails boot, and this names it without
a failed boot.

### Automatic updates

Both mechanisms below do the same two things: fetch the newest published
release and restart the server. Neither rolls anything back on its own. The
rollback is the pre-upgrade `pesque backup` (see
[Recovering from a bad update](#recovering-from-a-bad-update)); on the
systemd path the updater writes that backup for you.

#### Compose: a watchtower profile

The stack ships an opt-in `watchtower` service under the `auto-update`
profile. It polls GHCR on a schedule and recreates the server container when
the floating image's digest has moved:

```bash
echo 'COMPOSE_PROFILES=auto-update' >> .env
docker compose up -d
```

`COMPOSE_PROFILES` in `.env` carries the choice: every later
`docker compose` command on the project starts the watcher too, while a
stack without that line never launches one, however many times you run
`up -d`. That is also why this is a profile and not a default-on service.
Watchtower needs the Docker socket mounted, and the socket is root on the
host by another name: anything it can pull, it can run as root. Starting a
container that holds it without being asked would be a security decision
made on your behalf, so the default stack stays inert and opting in costs
one command.

What the service does with the choice:

- Checks daily at 03:17 UTC. The minute is deliberate: GHCR's shared bucket
  is empty for the first minutes of an hour, and midnight is when every
  cron in the world arrives.
- Checks once at startup too, so enabling the profile brings a stale server
  current immediately instead of waiting for the next window.
- Watches only containers carrying the
  `com.centurylinklabs.watchtower.enable=true` label: the `pesque` service
  has it, Caddy does not.
- Deletes the old image after an update (`WATCHTOWER_CLEANUP=true`).
- The watcher image is pinned (`nickfedor/watchtower:1.23.0`), the
  maintained fork, because `containrrr/watchtower` was archived in late
  2025. The fork's own README discourages production use; that is part of
  what opting in means, and worth reading before enabling this on a
  load-bearing host.

Watchtower updates the image, not your data: it takes no backup. Give
`pesque backup` a cron of its own (the archive is live-safe) so the
rollback story below holds. If you want an update to be an event rather
than a surprise, watchtower sends notifications through its
`WATCHTOWER_NOTIFICATIONS_*` variables.

Disable by removing `COMPOSE_PROFILES` from `.env` and pruning the orphan:

```bash
docker compose up -d --remove-orphans
```

**The tag is the fence.** The compose file uses
`ghcr.io/zeeetech/pesque:${PESQUE_TAG:-latest}`, and every release is
published to GHCR as `X.Y.Z`, a floating `X.Y`, and `latest`:

| `PESQUE_TAG` | What watchtower does | The risk you accept |
| --- | --- | --- |
| `latest` (default) | Follows every release, majors included | A pull can cross a major, and configuration is strict (an unknown key fails boot), so a major jump can leave the server down until you intervene |
| `1.4` | Follows every `1.4.x` patch; a new minor line needs a manual bump | Majors cannot sneak in, though a config change can still arrive within a line |
| `1.4.2` | Never moves; the digest does not change | No automation at all; the watcher is running for nothing |

Keep `latest` on a personal server whose backup cron you trust; use the
floating minor when the server hosts other people. If you build from source
(`PESQUE_BUILD=1` or the build override), do not enable the profile:
watchtower would replace your locally built image with the published one on
its next pass.

#### Release under systemd: a timer that runs `pesque update`

`contrib/systemd/` holds two units for the release install. The service is
a oneshot with two steps: `pesque backup --out /var/backups/pesque`, then
`pesque update`, which downloads the newest release tarball, verifies it
against its `SHA256SUMS`, swaps the `/opt/pesque` symlink and restarts the
`pesque` unit. If the backup fails, systemd never reaches the update, so a
full disk cannot turn into an unbacked upgrade.

```bash
sudo install -m 644 contrib/systemd/pesque-update.service \
  contrib/systemd/pesque-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pesque-update.timer
```

The timer fires Sundays at 03:17 with up to 15 minutes of jitter, and
`Persistent=true` catches up a machine that was off at the window. The
cadence is weekly, not nightly, because `pesque update` restarts the unit
even when the release is already current: a nightly timer would buy a
nightly restart for nothing. The archives in `/var/backups/pesque`
accumulate at one per update run; delete the old ones once a version has
been healthy for a while.

The units assume the host CLI at `/usr/local/bin/pesque` (adjust if yours
lives elsewhere), the service unit named `pesque` (set `PESQUE_SERVICE` in
the service unit if not), and the CLI's own convention of running one-off
verbs as the `pesque` user. Disable with
`systemctl disable --now pesque-update.timer`. To watch the whole thing
work without waiting for Sunday, `systemctl start pesque-update.service`,
then `pesque health`.

On NixOS, `pesque update` is a no-op on purpose: the version comes from the
flake, and releases arrive through `nixos-rebuild`.

### Recovering from a bad update

There is no down migration. Once a release has booted, its migrations are
in the database and an older binary cannot boot a newer data directory, so
downgrading the image or the `/opt/pesque` symlink alone is not a rollback.
The rollback is the pre-upgrade backup:

1. `pesque restore /var/backups/pesque/pesque-backup-<stamp>.tar.gz` (the
   systemd path; on compose, wherever your backup cron writes)
2. Pin the version that was running before: `PESQUE_TAG=1.4.2` in `.env`
   and `docker compose up -d`, or `pesque update <version>`, or point
   `/opt/pesque` at the previous release directory and restart
3. `curl /xrpc/_health`

With auto-update enabled, the pre-upgrade archive is the one the updater
wrote (systemd) or the most recent one your cron wrote (compose). A release
that fails its own boot check (the strict config check names the offending
key) is recovered the same way: restore, then remove the unknown key.

## Health and logs

`/xrpc/_health` runs `SELECT did FROM users LIMIT 1` rather than `SELECT 1`,
because a bare `SELECT 1` succeeds against an unmigrated database. `503` means
the server cannot read a single account; the reason is logged, never returned.
At boot:

```
[info] pesque up data_dir=/var/lib/pesque hostname=pds.example.com mode=conformant_single registration=closed
```

Log metadata is an allowlist (`did`, `handle`, `route`, `reason`, `path`,
`count`, `records`, `hostname`, `mode`, `registration`, `data_dir`); add keys
in `config/config.exs`.

## Retention

| What | Rule |
| --- | --- |
| Firehose events | dropped after 7 days; a cursor inside the window answers `OutdatedCursor` |
| Blocks | dropped when unreachable from the current MST root |

So `getBlocks` and `getRecord?cid=` for a superseded version answer not-found
after the sweep. Anything walking history needs to consume the firehose promptly.

## Limits

| What | Default | Where |
| --- | --- | --- |
| Blob upload | 5 MiB (`PDS_BLOB_UPLOAD_LIMIT`), in `describeServer.blobUploadLimit` | `Pesque.Blob` |
| Repo import | 100 MiB (`PDS_REPO_IMPORT_LIMIT`) | `PesqueWeb.Xrpc.RepoController` |
| Request body | 8 MB | `Plug.Parsers` |
| Firehose replay | 10,000 frames per connect | `PesqueWeb.Firehose` |
| Page sizes | 50 records (max 100), 500 repos/blobs (max 1000) | controllers |

Each write updates the MST incrementally against the stored root; a tree that
cannot be walked falls back to a full rebuild and logs it. `getRepo` streams the
CAR in batches.

## Rate limits and the proxy

Buckets: sessions (100/hour), reads (3000/5 min), writes (600/5 min), OAuth
(100/hour). Two keys per request: the account and the address. The tighter of the
two answers, and `ratelimit-*` and `retry-after` are set on both paths.

The address comes from `x-forwarded-for`, necessary behind a proxy and fatal
without one: **a directly reachable server has a per-address limit worth
nothing**. Counters are fixed-window, so a window seam can double the limit.

## Security notes

- OAuth (ES256, DPoP-bound, short-lived) and legacy sessions (HS256, no proof of
  possession) are both live. Browsers should use OAuth.
- `data/keys/oauth.p256.key` signs every access token and is published in the
  JWKS; losing it invalidates every outstanding OAuth token.
- Client metadata is fetched from a URL a stranger chose: https only, no
  redirects, private and loopback addresses refused, capped and timed out. DNS
  rebinding is not closed.
- CORS is `*`; authority travels in the token, not cookies.
- Blobs ship with `content-disposition: attachment`, `nosniff` and a restrictive
  CSP, so a `text/html` blob does not render from your origin.
- Registration is closed by default: invite codes, one per account, spent
  atomically. `createInviteCodes` is operator-only; under `path_multi` name
  yourself in `PDS_ADMIN_DIDS`.

## Data exposure

**Everything you write is public**, by protocol design, with no per-repo setting.
A deleted record is still in the blocks, and a firehose consumer that saw it has
it. That includes photos: a blob's CID sits in the record referencing it, and
EXIF is not stripped. Strip it client-side; a server that rewrites your bytes is
a server you can no longer verify.

**Email addresses are not exposed by any endpoint**, only stored. **Account
existence is public**: `listRepos` enumerates every hosted DID.

## Troubleshooting

- **`_health` returns 503.** Check `PDS_DATA_DIR`, write permission, migrations.
- **Boot dies on `unknown PDS_ variables` or `unknown key`.** The environment
  and the config file are both strict: a name the server does not read is
  refused, not ignored. `pesque config validate` names the offenders; the
  internal variables the tooling sets are `PDS_CONFIG`, `PDS_PUBLIC_IP` and
  `PDS_TAG`.
- **A `did:web` with a port does not resolve.** The port is only encoded for
  loopback and private hosts; fix the proxy.
- **The AppView shows nothing.** `path_multi` DIDs are ignored by ATProto
  resolvers, or the certificate is invalid.
- **Reads answer `RepoNotFound` for an account that exists.** The stored DID was
  minted under a different hostname or port. See
  [Changing hostname or port](identity.md#changing-hostname-or-port).
- **The firehose connects and goes silent.** Proxy buffering.
- **`MethodNotImplemented` with a 501.** The route does not exist.
