# Operations

Commands use Compose spelling (`./pesque`); on NixOS use `sudo pesque` and
`systemctl`. Source-development commands use `mix run -e 'Pesque.Cli.main()'`.

## Backup and restore

The data directory contains the database, keys, blobs and secret. `backup` writes
`pesque-backup-<stamp>.tar.gz` to the configured directory. It is live-safe:
SQLite is snapshotted with `VACUUM INTO`. Incomplete data directories are refused.

```bash
./pesque backup                 # Compose: ./backups
sudo pesque backup              # NixOS: services.pesque.backupDir
sudo systemctl start pesque-backup
```

Backups write only to their configured directory (`--out /backups` is accepted
for scripts; any other directory is refused). The Compose command prepares
directory ownership so archives remain host-readable. Restore is cold: stop
Pesque first. Compose refuses while the service runs; NixOS refuses while its
unit is active or the container still exists.

```bash
docker compose stop pesque
./pesque restore pesque-backup-20261011T123456Z.tar.gz
docker compose up --detach --wait

sudo systemctl stop pesque
sudo pesque restore pesque-backup-20261011T123456Z.tar.gz
sudo systemctl start pesque
```

Pass an archive filename, not a path. `restore --dry-run` verifies without
changing data. Restore stages and checks the manifest before swapping; after a
crash, the prior state and archive remain. Migrations run at boot, so newer data
cannot be opened by an older binary. Archives contain `server.secret`; losing it
invalidates legacy sessions.

## Data and permissions

```text
data/
├── pesque.db                    # accounts, records, blocks, blobs, events, invites, OAuth state
├── server.secret                # legacy session HMAC secret
├── keys/<digest>.key            # per-DID secp256k1 signing key
├── keys/<digest>.rotation.key   # did:plc recovery key
├── keys/oauth.p256.key          # OAuth signing key
└── blobs/<digest>/<cid>         # blob bytes
```

`server.secret` and key files are mode `0600`; the data directory and `keys/`
are `0700`. Backup archives are `0600` by default; Compose deliberately changes
them to `0640` with the operator group so the host can read them while others
have no access. Under Compose the data is the `pesque-data` volume; under NixOS
it is `dataDir`, owned by the configured UID/GID.

Protect the directory: leaks can forge legacy sessions (`server.secret`), OAuth
tokens (`oauth.p256.key`), PLC identities (rotation keys), or commits (signing
keys). The database contains email addresses, Argon2 password hashes, records
and events. Blobs are public by protocol.

## Accounts and browser flows

Pesque sends no email. Confirmation codes are logged for the operator to relay
to the account holder. Codes expire after 15 minutes, are single-use, and use
`XXXXX-XXXXX` from the official client's base32 alphabet (no `0`, `1`, `8` or `9`).
Available operator commands:

| Purpose | Command |
| --- | --- |
| PLC signature, identity changes or move-out | `account plc-token --did D \| --handle H` |
| Email confirmation or change | `account email-token --did D \| --handle H` |
| Password reset | `account reset-token --did D \| --handle H` |

`requestPasswordReset` is anonymous and returns no code; only the log contains
it. Completing `resetPassword` ends all sessions. `signPlcOperation` returns a
signed operation for the client to submit to the PLC directory or destination PDS.

Other CLI operations include `account list|show|delete|takedown|activate|reset-password|app-passwords|revoke-app-password`; each accepts `--help`, and read commands accept `--json`. XRPC deletion uses `requestAccountDelete` then `deleteAccount` with the token and password; rows, blocks, blobs and keys are removed, but firehose events remain. Deactivation stops writes without changing the repo. App passwords are independently revocable; resetting the account password does not revoke them. Invite codes come from `invite create` or operator-authorized `createInviteCodes`; `getAccountInviteCodes` lists codes assigned to the calling account.

Browser clients should use OAuth; legacy HS256 sessions have no proof of possession. In `multi`, `/signup` creates an account (invite required when registration is closed), asking for handle, email and a password of at least eight characters. Pesque sends no confirmation email; the address is for operator-assisted recovery. The confirmation page shows the handle and directs the account holder to sign in with the official app.

`/migrate` asks for the old PDS URL, full handle, email and account password, not an app password; a closed server also requires an invite. The page shows copy progress, then asks for the code sent by the old PDS; it reports success or failure. If a move fails before the identity switch, the old account keeps working. These pages are unavailable in `single`; new browser accounts use `did:plc`.

## Moving an account in

An account move preserves its DID and handle. This server must run `multi` behind TLS. Configure `crawler` if you want relay discovery and run `pesque doctor` as federation preflight. Before importing, publish `_atproto.<handle>` DNS TXT and the well-known document to match the DID document's `alsoKnownAs`.

Use the old PDS account password, not an app password. The move requires a full-access session; disable 2FA if the old PDS requires it. The old PDS holds the rotation key and signs the identity change. Once submitted, the old PDS no longer controls the identity; moving off `bsky.social` cannot be undone.

```bash
./pesque migrate \
  --old-pds https://bsky.social \
  --handle alice.example.com \
  --email alice@example.com
```

The command signs in to the old PDS, creates a deactivated account here, imports the repo and blobs, requests this server's DID credentials, obtains and submits the PLC operation, then activates this account and deactivates the old one. On `bsky.social`, the code arrives by email. A failure before PLC submission can be retried; the account is reused. For non-interactive runs, set `MIGRATE_PLC_TOKEN=XXXXX-XXXXX` to skip the code request step.

`submitPlcOperation` accepts only this server as PDS endpoint, the account's signing key and a matching `alsoKnownAs` handle. The first `getRecommendedDidCredentials` call creates the rotation key in the data directory. Hosted handles need wildcard or per-handle DNS; a proxy with on-demand TLS can issue certificates as names are reached. Moving out reverses the process: the destination runs the move and this server signs the identity step. The operator gets the code from logs or `account plc-token`, not email.

## Sync support

| XRPC surface | Support and bounds |
| --- | --- |
| `com.atproto.sync.getRepo` | Full CAR export; explicitly rejects `since`. Historical repo diffs are not supported. |
| `com.atproto.sync.listBlobs` | Supported; explicitly rejects `since`. |
| `com.atproto.sync.listRepos`, `com.atproto.sync.listReposByCollection`, `com.atproto.sync.getRepoStatus` | Supported. |
| `com.atproto.sync.subscribeRepos` | Live stream with bounded replay and live queues; connection rate and concurrency caps apply. |
| `com.atproto.sync.getBlocks` | Combined response limited by `sync_blocks_limit` (50,000,000 bytes by default). |
| Relay-role methods | `getHostStatus`, `listHosts`, `requestCrawl` and `notifyOfUpdate` are outside the PDS surface. |

## Legal pages

Set `privacy_policy_url` and `terms_of_service_url` to your legal pages;
`describeServer` advertises them. Unset keys omit the links. The image serves
placeholder `/privacy-policy.md` and `/terms-of-service.md`; replace them
before advertising a real domain.

## Upgrades and recovery

Updates are manual:

1. Run `pesque backup`; it is safe while live.
2. Replace the release. Compose: unpack a newer bundle or update its image
   tag, then `docker compose up --detach --wait`. NixOS: set a new pinned image
   and run `nixos-rebuild switch`.
3. Run `pesque config validate` and check `/xrpc/_health`.

There is no down migration: an older binary cannot open a database migrated by
a newer release. To roll back, stop the server, restore the pre-upgrade archive,
return to the previous release, start it and check `/xrpc/_health`. If boot
rejects an unknown config key, restore if needed and correct or remove the key.

## Health, retention and limits

`/xrpc/_health` reads an account row, so it detects an unmigrated database; 200
is healthy, while 503 means the server cannot read an account. The reason is
logged, not returned. Compose uses the image health check; use
`journalctl -u pesque -f` on NixOS. `pesque health` inspects the running
container without starting it. The boot log includes data directory, hostname,
mode and registration; logged metadata is allowlisted in `config/config.exs`.

| Resource | Limit or retention |
| --- | --- |
| Firehose events | 7 days; older cursors return `OutdatedCursor` |
| Blocks | Removed when unreachable from the current MST root |
| Blob upload | 5 MiB by default (`blob_upload_limit`); advertised by `describeServer` |
| Repo import | 100 MiB (`repo_import_limit`) |
| `getBlocks` payload | 50,000,000 bytes (`sync_blocks_limit`) per request |
| Request body | 8 MB |
| Record block | 1,000,000 bytes CBOR |
| Commit CAR | 2,000,000 bytes |
| Commit operations | 200 per write |
| Firehose frame | 5,000,000 bytes |
| Firehose replay | 10,000 frames and 50 MiB (`firehose_replay_limit`) per connection |
| Live firehose queue | 100 frames (`firehose_pending_frame_limit`) and 50 MiB (`firehose_pending_byte_limit`) per connection |
| Firehose connection attempts | 5/IP/minute (`firehose_connection_rate_limit`) |
| Concurrent firehose connections | 4/IP (`firehose_ip_connection_limit`), 64 global (`firehose_global_connection_limit`) |
| Page sizes | 50 records (max 100); 500 repos/blobs (max 1000); 500 repos by collection (max 2000) |

After unreachable blocks are swept, `getBlocks` and `getRecord?cid=` return not-found. Consumers needing history must read the firehose promptly. Writes update the MST incrementally; an unwalkable tree falls back to a logged full rebuild. `getRepo` streams CAR data in batches.

## Rate limits and proxy

Request buckets are sessions (100/hour), reads (3000/5 minutes), writes (600/5 minutes), OAuth (100/hour), and firehose connection attempts (5/minute). Ordinary buckets count account and address; the tighter limit applies. Firehose attempts are address-only. `ratelimit-*` and `retry-after` describe attempt-rate refusals. Concurrent connections are separately capped at 4 per address and 64 globally; saturation returns 429 per address or 503 globally.

Live queue limits include the incoming frame: an exact-limit frame is accepted; an over-limit frame causes `#info` with `ConsumerTooSlow` and closes the connection without enqueueing it. These budgets cover live messages, not replay. Only binary firehose messages count in a mailbox scan; an oversized raw mailbox closes without scanning. The address comes from `x-forwarded-for`, which requires a trusted proxy. Direct access makes per-IP limits ineffective. Fixed-window counters can double a limit at a window boundary.

## Security and data exposure

- OAuth uses short-lived ES256 tokens bound to DPoP; legacy sessions use HS256 without proof of possession. Browsers should use OAuth.
- Losing `keys/oauth.p256.key` invalidates outstanding OAuth tokens.
- OAuth client metadata fetches require HTTPS, disallow redirects and private or loopback addresses, and are capped and timed out. DNS rebinding is not prevented.
- CORS is `*`; authority is in the token, not cookies.
- Blob responses use attachment disposition, `nosniff` and restrictive CSP.
- Registration is closed by default. Invite codes are single-use and spent atomically; `createInviteCodes` is operator-only and requires your DID in `admin_dids` under `multi`.

Everything written to a repo is public by protocol, including deleted records and blobs already seen by firehose consumers. Blob CIDs appear in records; EXIF is not stripped. Email addresses are not exposed by endpoints, but account existence is public through `listRepos`.

## Troubleshooting

- **`_health` returns 503:** check the data mount, write permissions and migrations.
- **Boot reports an unknown key or invalid setting:** settings belong in `pesque.conf`; `PDS_CONFIG` selects the file. The error names the file, key and line. Run `pesque config validate`.
- **`did:web` does not resolve:** confirm the public hostname, HTTPS document, proxy and advertised port.
- **The AppView shows nothing or reads return `RepoNotFound`:** the DID may have been minted for another hostname or port. Check [configuration](installation.md#configuration).
- **The firehose connects but stays silent:** disable proxy buffering.
- **A method returns 501 `MethodNotImplemented`:** that route is not implemented; see [Sync support](#sync-support) for sync methods.
