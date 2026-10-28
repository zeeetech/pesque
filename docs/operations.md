# Operations

Running a server that has real data in it.

Commands below are written in the Compose bundle's spelling (`./pesque` in
the bundle directory, `docker compose` for lifecycle). On NixOS the same
verbs are `sudo pesque ...` and lifecycle is `systemctl`.

## Backup and restore

The data directory (`/data` in the container) is the whole server: the
database, the keys, the blobs and the secret. Both deployment paths bind a
host-visible backup directory at `/backups`, and `backup` and `restore`
speak only to that directory.

`pesque backup` writes `pesque-backup-<stamp>.tar.gz` and is safe to run
while the server is up: the database is snapshotted with `VACUUM INTO`
first, so the archive holds the committed state at one instant. The verb
refuses a data directory that is missing a piece every booted server has: an
archive that looks complete and restores into a server that cannot boot is
worse than a refused backup.

```bash
./pesque backup                      # docker: archives land in ./backups
sudo pesque backup                   # NixOS: archives land in backupDir
sudo systemctl start pesque-backup   # NixOS: the same backup as a oneshot, for timers
```

Both commands write only to their own backup directory (`--out /backups` is
accepted for scripts; any other directory is refused). On docker the command
prepares the directory's ownership itself, so archives are readable from the
host and still owned by the container's non-root user.

Restore is cold, and both host commands enforce it: docker refuses while the
Compose service is running, NixOS refuses while the unit is active or its
container exists. Stop the server first:

```bash
# docker
docker compose stop pesque
./pesque restore pesque-backup-20261011T123456Z.tar.gz
docker compose up --detach --wait

# NixOS
sudo systemctl stop pesque
sudo pesque restore pesque-backup-20261011T123456Z.tar.gz
sudo systemctl start pesque
```

The archive is named as a filename inside the backup directory, nothing
else. `restore --dry-run` verifies an archive without touching anything. A
real restore extracts into a staging directory and verifies against the
archive's manifest before anything moves; a crash mid-swap leaves the
previous state next to the new one, and the archive itself is always the way
back.

Migrations run at boot, so restoring onto a newer binary is fine; a newer
data directory onto an older binary is not. The archive carries
`server.secret`, so treat it as you would the data directory: lose it and
every legacy session dies.

## The data directory

```
data/
├── pesque.db            SQLite: accounts, records, blocks, blobs, events, invites, preferences, OAuth state
├── server.secret        HMAC secret for legacy session tokens
├── keys/<digest>.key            secp256k1 signing key per DID
├── keys/<digest>.rotation.key   did:plc rotation key, the account's only recovery path
├── keys/oauth.p256.key          P-256 key OAuth tokens and the JWKS are signed with
└── blobs/<digest>/<cid> blob bytes, addressed by CID
```

Key files are named after a SHA-256 digest of the DID, because a DID is not
a filename. Sensitivity, highest first:

| What | If it leaks |
| --- | --- |
| `server.secret` | Mint a valid legacy session for any account |
| `keys/oauth.p256.key` | Mint access tokens for any account |
| `keys/*.rotation.key` | Take over a did:plc identity |
| `keys/*.key` | Forge commits for one account |
| `pesque.db` | Emails, password hashes (Argon2), records, events |
| `blobs/` | Public by protocol |

Secrets are `0600` and `keys/` is `0700`; the data directory takes your
umask. Under Docker this directory is the named volume `pesque-data`; under
NixOS it is `dataDir`, owned by the `uid`/`gid` you set.

## Accounts

Pesque sends no email. Every confirmation code reaches you, the operator,
through the server log when a client asks for one, and you relay it to the
account holder; each verb below mints a fresh code on demand. Codes are good
for 15 minutes, single use, and shaped `XXXXX-XXXXX` (the base32 alphabet
the official client requires, no `0`, `1`, `8` or `9`).

| Flow | Mint on demand |
| --- | --- |
| PLC operation signature (identity changes, moving out) | `pesque account plc-token --did D \| --handle H` |
| Email confirmation, email change | `pesque account email-token --did D \| --handle H` |
| Password reset | `pesque account reset-token --did D \| --handle H` |

`requestPasswordReset` is anonymous, so its code never appears in a response
body, only in the log: a stranger cannot reset an account whose log they do
not read. A completed `resetPassword` ends every session the account held.
`signPlcOperation` answers with the signed operation rather than submitting
it; the client submits it to the PLC directory or to the PDS the account is
moving to.

The rest of the operator surface is `pesque account list | show | delete |
takedown | activate | reset-password | app-passwords | revoke-app-password`
(every verb takes `--help`, the read ones take `--json`). Over XRPC,
`deleteAccount` is two-step: `requestAccountDelete` returns a token in the
body (no email is sent), then `deleteAccount` spends it with the password;
rows, blocks, blobs and keys go, firehose events stay. `deactivateAccount` /
`activateAccount` stop and resume writes without touching the repo. App
passwords are named, revocable credentials an account's apps log in with;
`revoke-app-password` is the recovery path when a user reports a compromised
or forgotten one, because a password reset revives the account password but
leaves the app-password rows alone. Invite codes are minted by the operator
(`pesque invite create`, or `createInviteCodes` with your DID named in
`admin_dids`); `getAccountInviteCodes` lists the codes earmarked for the
calling account.

## Moving an account in

Moving an existing ATProto account onto this server. The DID does not
change, so the handle's DNS record does not change either and keeps
resolving throughout the move. Two servers are involved: the old PDS, which
still holds the account, and this one.

### Before you start

- This server runs `mode = multi`, behind TLS, with `crawler` set if you
  want a relay to pick it up.
- The handle is verified before it is accepted: DNS TXT at
  `_atproto.<handle>`, then the well-known document, cross-checked against
  the DID document's `alsoKnownAs`. Publish the record first or the import
  is refused.
- The password you are prompted for is the old PDS account password, and it
  becomes the new account's password. Not an app password: the PLC endpoints
  the move relies on require a full-access session, and the old PDS answers
  `400 Bad token scope` for anything less. If the account has 2FA, turn it
  off for the move; the verb cannot supply a second factor.
- The old PDS holds the rotation key and signs the identity step. Once that
  signature lands, the move is one-way: the old PDS no longer controls the
  identity. Migrating off `bsky.social` cannot be undone.

### One command

```bash
./pesque migrate \
  --old-pds https://bsky.social \
  --handle alice.example.com \
  --email alice@example.com
```

(`sudo pesque migrate ...` on NixOS; `mix run -e 'Pesque.Cli.main()' migrate
...` from source.) What it does, in order: opens a session on the old PDS,
creates the account here (deactivated), imports the repo and every blob,
fetches this server's recommended DID credentials, asks the old PDS to sign
the PLC operation carrying them (on `bsky.social` that emails a code to the
account holder, which the prompt asks for), submits the operation here,
activates the new account and deactivates the old one. A run that fails
before the PLC submission is safe to re-run: the account is reused rather
than recreated.

Where there is no terminal to prompt on, pass the code through the
environment instead: get it from wherever the old PDS delivered it, then
`MIGRATE_PLC_TOKEN=XXXXX-XXXXX ./pesque migrate ...` skips the request step
and completes the move.

### Caveats

- This server's `submitPlcOperation` refuses an operation whose PDS endpoint
  is not this server, whose signing key is not the account's, or whose
  `alsoKnownAs` does not claim the account's handle.
- `getRecommendedDidCredentials` mints this server's rotation key on the
  first ask; it lives in the data directory from then on.
- A handle this server itself hosts needs a DNS record for the name (a
  wildcard `*.<handle-domain>` or one per handle). A proxy with on-demand
  TLS issues the certificates as clients reach the names
  ([Installation](installation.md#behind-a-tls-proxy)); a handle on a domain
  you do not control is verified by a TXT record instead.
- Moving an account out is the same dance in reverse: the destination PDS
  runs the move, this server signs the identity step (`signPlcOperation`),
  and the confirmation code reaches you, the operator, through the log or
  `pesque account plc-token` ([Accounts](#accounts)), not an inbox.

## Replace the legal pages

`describeServer` advertises the links you set: `privacy_policy_url` and
`terms_of_service_url` in the conf. Unset, the links are omitted. The image
also serves placeholder `/privacy-policy.md` and `/terms-of-service.md`;
point the conf keys at pages you actually stand behind before advertising a
real domain.

## Upgrades

Updates are manual; nothing updates on its own.

1. `pesque backup` (live-safe; no stop needed)
2. Replace the release. Docker: unpack a newer bundle over the deployment
   directory (or edit the image tag in `compose.yaml`), then
   `docker compose up --detach --wait` recreates the container on the new
   image; the data volume survives. NixOS: raise `services.pesque.image` to
   the new pinned tag and `nixos-rebuild switch`.
3. `curl /xrpc/_health`, which reads a table, so it is the migration check

Run `pesque config validate` after the swap: an unknown `PDS_*` variable or
conf key fails boot, and the validate verb names it without a failed boot.

### Recovering from a bad update

There is no down migration. Once a release has booted, its migrations are in
the database and an older binary cannot boot a newer data directory, so
moving the image tag back alone is not a rollback. The rollback is the
pre-upgrade backup:

1. Stop the server (docker: `docker compose stop pesque`; NixOS:
   `sudo systemctl stop pesque`)
2. `pesque restore <archive name>`
3. Move back to the previous release: docker, the previous bundle's
   `compose.yaml` (or the old tag) and `docker compose up --detach --wait`;
   NixOS, the previous `image` tag and `nixos-rebuild switch`
4. `curl /xrpc/_health`

A release that fails its own boot check (the strict config check names the
offending key) is recovered the same way: restore, then remove the unknown
key.

## Health and logs

`/xrpc/_health` runs `SELECT did FROM users LIMIT 1` rather than `SELECT 1`,
because a bare `SELECT 1` succeeds against an unmigrated database. `503`
means the server cannot read a single account; the reason is logged, never
returned. At boot:

```
[info] pesque up data_dir=/var/lib/pesque hostname=pds.example.com mode=single registration=closed
```

Log metadata is an allowlist (`did`, `handle`, `route`, `reason`, `path`,
`count`, `records`, `hostname`, `mode`, `registration`, `data_dir`); add
keys in `config/config.exs`.

Docker: `docker compose logs -f pesque`, and the image's `HEALTHCHECK` is
what `up --detach --wait` waits on. NixOS: `journalctl -u pesque -f`, and
`pesque health` inspects the running container without starting anything.

## Retention

| What | Rule |
| --- | --- |
| Firehose events | dropped after 7 days; a cursor inside the window answers `OutdatedCursor` |
| Blocks | dropped when unreachable from the current MST root |

So `getBlocks` and `getRecord?cid=` for a superseded version answer
not-found after the sweep. Anything walking history needs to consume the
firehose promptly.

## Limits

| What | Default | Where |
| --- | --- | --- |
| Blob upload | 5 MiB (`PDS_BLOB_UPLOAD_LIMIT`), in `describeServer.blobUploadLimit` | `Pesque.Blob` |
| Repo import | 100 MiB (`PDS_REPO_IMPORT_LIMIT`) | `PesqueWeb.Xrpc.RepoController` |
| Request body | 8 MB | `Plug.Parsers` |
| Firehose replay | 10,000 frames per connect | `PesqueWeb.Firehose` |
| Page sizes | 50 records (max 100), 500 repos/blobs (max 1000) | controllers |

Each write updates the MST incrementally against the stored root; a tree
that cannot be walked falls back to a full rebuild and logs it. `getRepo`
streams the CAR in batches.

## Rate limits and the proxy

Buckets: sessions (100/hour), reads (3000/5 min), writes (600/5 min), OAuth
(100/hour). Two keys per request: the account and the address. The tighter
of the two answers, and `ratelimit-*` and `retry-after` are set on both
paths.

The address comes from `x-forwarded-for`, necessary behind a proxy and fatal
without one: **a directly reachable server has a per-address limit worth
nothing**. Counters are fixed-window, so a window seam can double the limit.

## Security notes

- OAuth (ES256, DPoP-bound, short-lived) and legacy sessions (HS256, no
  proof of possession) are both live. Browsers should use OAuth.
- `data/keys/oauth.p256.key` signs every access token and is published in
  the JWKS; losing it invalidates every outstanding OAuth token.
- Client metadata is fetched from a URL a stranger chose: https only, no
  redirects, private and loopback addresses refused, capped and timed out.
  DNS rebinding is not closed.
- CORS is `*`; authority travels in the token, not cookies.
- Blobs ship with `content-disposition: attachment`, `nosniff` and a
  restrictive CSP, so a `text/html` blob does not render from your origin.
- Registration is closed by default: invite codes, one per account, spent
  atomically. `createInviteCodes` is operator-only; under `multi` name
  yourself in `PDS_ADMIN_DIDS`.

## Data exposure

**Everything you write is public**, by protocol design, with no per-repo
setting. A deleted record is still in the blocks, and a firehose consumer
that saw it has it. That includes photos: a blob's CID sits in the record
referencing it, and EXIF is not stripped. Strip it client-side; a server
that rewrites your bytes is a server you can no longer verify.

**Email addresses are not exposed by any endpoint**, only stored. **Account
existence is public**: `listRepos` enumerates every hosted DID.

## Troubleshooting

- **`_health` returns 503.** Check the data mount, write permission,
  migrations.
- **Boot dies on `unknown PDS_ variables` or `unknown key`.** The
  environment and the config file are both strict: a name the server does
  not read is refused, not ignored. `pesque config validate` names the
  offenders.
- **A `did:web` with a port does not resolve.** The port is only encoded for
  loopback and private hosts; fix the proxy.
- **The AppView shows nothing.** The account's DID document is not
  resolving: an invalid certificate on the endpoint, or a DID minted under a
  different hostname or port.
- **Reads answer `RepoNotFound` for an account that exists.** The stored DID
  was minted under a different hostname or port. See
  [Configuration](installation.md#configuration).
- **The firehose connects and goes silent.** Proxy buffering.
- **`MethodNotImplemented` with a 501.** The route does not exist.
