# Operations

Running a server that has real data in it.

## Backup and restore

`PDS_DATA_DIR` is the whole server. Stop, copy, start:

```bash
systemctl stop pesque
tar czf pesque-$(date +%F).tar.gz -C /var/lib pesque
systemctl start pesque
```

Migrations run at boot, so restoring onto a newer binary is fine; a newer data
directory onto an older binary is not. A `cp -r` of a running server can leave a
row whose file never landed or a file whose row never committed: the first
answers `BlobNotFound`, the second is an orphan, and both clear on the next
sweep. The one file where a partial copy matters is `data/server.secret`: lose it
and every legacy session dies.

## The data directory

```
data/
├── pesque.db            SQLite: accounts, records, blocks, events, invites, OAuth state
├── server.secret        HMAC secret for legacy session tokens
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
- `com.atproto.server.createInviteCodes` mints codes, operator-only (see below).

## Replace the legal pages

`describeServer` advertises `/privacy-policy.md` and `/terms-of-service.md` from
`priv/static/`. They ship as placeholders; replace them before pointing a real
domain at the server.

## Upgrades

1. `bin/pesque stop` (clean `SIGTERM`)
2. Replace the release directory
3. `bin/pesque start`, migrations run at boot
4. `curl /xrpc/_health`, which reads a table, so it is the migration check

There is no down migration; rolling back means restoring a pre-upgrade backup.

## Health and logs

`/xrpc/_health` runs `SELECT did FROM users LIMIT 1` rather than `SELECT 1`,
because a bare `SELECT 1` succeeds against an unmigrated database. `503` means
the server cannot read a single account; the reason is logged, never returned.
At boot:

```
[info] pesque up data_dir=/var/lib/pesque hostname=pds.example.com mode=conformant_single registration=closed
```

Log metadata is an allowlist (`did`, `handle`, `route`, `reason`, `hostname`,
`mode`, `registration`, `data_dir`); add keys in `config/config.exs`.

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
- **A `did:web` with a port does not resolve.** The port is only encoded for
  loopback and private hosts; fix the proxy.
- **The AppView shows nothing.** `path_multi` DIDs are ignored by ATProto
  resolvers, or the certificate is invalid.
- **Reads answer `RepoNotFound` for an account that exists.** The stored DID was
  minted under a different hostname or port. See
  [Changing hostname or port](identity.md#changing-hostname-or-port).
- **The firehose connects and goes silent.** Proxy buffering.
- **`MethodNotImplemented` with a 501.** The route does not exist.
