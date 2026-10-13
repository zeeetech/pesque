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
- `com.atproto.server.requestEmailConfirmation` / `confirmEmail` prove an
  account's email, and `com.atproto.server.requestPasswordReset` /
  `resetPassword` replace a password with a code. Both are two-step, and both
  codes reach the operator the way the PLC code does: logged when a client
  asks, and mintable on demand with `pesque account email-token --did D |
  --handle H` or `pesque account reset-token --did D | --handle H`. Each is
  good for 15 minutes and single use; `confirmEmail` / `resetPassword` spend
  it. `requestPasswordReset` is anonymous, so its code is never in the response
  body: a stranger cannot reset an account whose log they do not read. A
  `confirmEmail` stamps the time the address was proven; a `resetPassword` also
  ends every session the account held.
- `com.atproto.server.updateEmail` moves an account to a new address. A
  confirmed address takes a code from `com.atproto.server.requestEmailUpdate`,
  which answers `tokenRequired` and logs the code (or mints nothing when the
  address was never confirmed, so the move needs no token). The code is the
  same kind `confirmEmail` spends and reaches the operator the same way
  (`pesque account email-token`). The new address starts unconfirmed: its own
  `confirmEmail` code is what proves it.
- App passwords (`com.atproto.server.createAppPassword` and friends) are
  named, revocable credentials an account's apps log in with. A plain one
  opens a reduced session (records, blobs, preferences, non-chat rpc); a
  privileged one reaches the account state a password login does, except that
  it cannot create app passwords. `pesque account app-passwords --did D |
  --handle H` lists an account's credentials (name, privilege, created at;
  the passwords themselves are unrecoverable by construction) and `pesque
  account revoke-app-password --did D | --handle H --name N` revokes one and
  every session opened with it. That is the recovery path when a user reports
  a compromised or forgotten app password: a password reset revives the
  account password but leaves the app-password rows alone.
- `com.atproto.server.createInviteCodes` mints codes, operator-only (see below),
  and `com.atproto.server.getAccountInviteCodes` lists the codes earmarked for
  the calling account (`for_accounts` names it). pesque's codes are minted by
  the operator, so a code created for nobody is returned to no one, and
  `includeUsed: false` drops codes with no uses left.
- `com.atproto.temp.checkHandleAvailability` answers whether a handle is free
  and, when it is not, suggests available ones, using the request's email for
  one of them. It is public: handle availability is the same fact `listRepos`
  already publishes. The session endpoints also carry `emailConfirmed` next to
  the email, wherever the email itself is visible.

## Replace the legal pages

`describeServer` advertises `/privacy-policy.md` and `/terms-of-service.md` from
`priv/static/`. They ship as placeholders; replace them before pointing a real
domain at the server.

## Upgrades

Updates are manual; nothing updates on its own. On docker, `pesque update
[tag]` pulls the image and recreates the container with the same settings
(the data volume survives the recreate): with no tag it re-pulls the running
image's tag, with a tag it moves to that release. On systemd, NixOS included,
`pesque update` is a no-op: the release is managed outside the CLI, so replace
it and restart the unit, or run `nixos-rebuild switch`.

The underlying flow, spelled out once:

1. `pesque backup` (live-safe; no stop needed)
2. stop the server (docker: `pesque down`; systemd: `systemctl stop pesque`)
3. replace the release (docker: `pesque update`; systemd: swap the release)
4. start it again, migrations run at boot
5. `curl /xrpc/_health`, which reads a table, so it is the migration check

`pesque config validate` boots nothing: it reads the environment and
`pesque.conf` the way the server will at boot, then prints every resolved
setting with the layer that decided it, the environment variable,
`pesque.conf:LINE`, or `(default)`. Run it after replacing the release: an
unknown `PDS_*` variable or config key fails boot, and this names it without
a failed boot.

### Recovering from a bad update

There is no down migration. Once a release has booted, its migrations are
in the database and an older binary cannot boot a newer data directory, so
downgrading the image or the `/opt/pesque` symlink alone is not a rollback.
The rollback is the pre-upgrade backup:

1. `pesque restore <archive>`: on docker the CLI stops the container, restores
   and starts it again; on systemd stop the unit first, then run restore as the
   service user (`sudo -u pesque pesque restore <archive>`)
2. Move the server back to the release that was running before: on docker
   `pesque update <version>`, on systemd point the release (or the
   `/opt/pesque` symlink) at the previous directory and restart the unit, or on
   NixOS check out the previous revision and run `nixos-rebuild switch`
3. `curl /xrpc/_health`

A release that fails its own boot check (the strict config check names the
offending key) is recovered the same way: restore, then remove the unknown
key.

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
