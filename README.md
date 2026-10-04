# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

A minimal, self-hosted ATProto Personal Data Server written in Elixir.

It runs on one SQLite file and one directory of blobs. No Postgres, no S3, no
cluster. The protocol parts (CIDs, the Merkle Search Tree, DAG-CBOR, CAR
archives, JWTs, secp256k1 signing) are built here directly rather than pulled
in, so the whole thing is small enough to read and specific enough to run.

The name sounds like PDS and means "go fish" in Portuguese, which felt right for
a server that feeds the firehose.

## Run it

Needs Elixir 1.18+ and a C toolchain for the SQLite driver.

```bash
mix deps.get
mix phx.server
```

```bash
curl http://localhost:4000/xrpc/_health
```

Migrations run on boot. `_health` queries the database, so a server whose
migrations never ran answers `503` rather than a cheerful ok. Point your uptime
monitor at it.

## Deploy it

```bash
docker build -t pesque .
docker run -d --name pesque -p 4000:4000 \
  -v pesque-data:/data \
  -e PDS_HOSTNAME=pds.example.com \
  pesque
```

Set `PDS_HOSTNAME` to the real address, or the advertised URLs and the
`did:web` will say `localhost`.

Put Caddy or nginx in front of it for TLS. The container speaks plain HTTP and
advertises `https`, which is what it should be behind a proxy.

### As a release

Without a container, `mix release` builds the same server as a self-contained
OTP release. It needs a writable `PDS_DATA_DIR` and nothing else.

```bash
MIX_ENV=prod mix release
_build/prod/rel/pesque/bin/pesque start
```

`bin/pesque stop` is `SIGTERM` with a clean exit: the endpoint drains, the repo
processes finish, and SQLite's write-ahead log survives the restart. Killing it
with `SIGKILL` works too and loses at most the commit in flight.

```ini
# /etc/systemd/system/pesque.service
[Service]
Type=simple
User=pesque
Environment=PDS_DATA_DIR=/var/lib/pesque
Environment=PDS_HOSTNAME=pds.example.com
ExecStart=/opt/pesque/bin/pesque start
ExecStop=/opt/pesque/bin/pesque stop
Restart=on-failure
```

Copy the release out of `_build` and run `bin/pesque` from wherever you put it;
the path in `ExecStart` is the only thing that has to change.

## Create an account

Registration is closed by default. From the host:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com --password secret123
```

```
created alice.example.com (did:web:example.com)
```

It boots the whole app, so stop the server first or use a different
`PDS_PORT`. `PDS_REGISTRATION=open` turns `createAccount` into an open
endpoint, which is only a good idea where you want strangers holding accounts.

## Before you put real data on it

**Everything you write is public.** `getRecord`, `listRecords`, `getRepo`,
`getLatestCommit`, `describeRepo`, `subscribeRepos` and `getBlob` answer
without a token, by protocol design. There is no per-repo visibility setting
and adding one would break the protocol. Treat every record as published.

**Which includes the photos.** A blob's CID sits inside the record referencing
it, so every image a post points at is fetchable by anyone who reads the post,
forever, no rate limit. EXIF is not stripped either, so location and device
data ride along in the JPEG. Strip it client-side before uploading.

**`:path_multi` will not federate to the public Bluesky network.** It uses
`did:web:example.com:user:alice`. W3C allows that, ATProto does not, so ATProto
resolvers ignore it. That is the cost of not depending on Bluesky's PLC
directory. Use `:conformant_single` to be on the public network.

**The public AppView rendering a `did:web` identity is untested.** It needs a
real HTTPS hostname and a live account. Assume nothing either way.

**Writes get slower as a repo grows.** Each write rebuilds the whole MST
instead of updating it, and `getRepo` builds the entire CAR in memory (~1MB per
500 records). Blocks are never pruned. Fine for thousands of records, not for
tens of thousands. This is the first thing I would change.

## Not implemented

- **OAuth.** Sessions are legacy HS256 bearer tokens. No PAR, no DPoP, no
  scopes.
- **`did:plc` and server-to-server sync.** Two Pesque instances do not talk to
  each other.
- **AppView.** This serves a PDS, not a feed.
- **`deactivateAccount`, `migrateTo`, `getServiceAuth`.** The rest of
  `com.atproto.server.*` and `com.atproto.repo.*` the spec names are answered;
  these three are not, and answer `501` rather than pretending.

## Endpoints

Repo: `createRecord`, `putRecord`, `deleteRecord`, `getRecord`, `listRecords`
Sync: `getRepo`, `getLatestCommit`, `subscribeRepos`
Blobs: `uploadBlob`, `getBlob`
Server: `describeServer`, `checkAccountStatus`, `createAccount`, `createSession`, `refreshSession`, `getSession`, `deleteSession`
Identity: `resolveHandle`, `describeRepo`, `did:web` documents

`describeServer` and `checkAccountStatus` answer without a token. Everything
else that writes, or that names a repo, needs one.

Session endpoints are capped at 100 requests an hour per address and per
account, and the read endpoints at 3000 per five minutes, which is what the
spec asks for. The address is read from `x-forwarded-for`, because behind
Caddy every request arrives from the proxy and one caller would otherwise spend
the whole server's budget. A server reachable directly, with no proxy, is a
server whose per-address limit is worth nothing: anyone can forge the header.

## Modes

| Mode | DID | Accounts |
| --- | --- | --- |
| `:conformant_single` (default) | `did:web:example.com` | one |
| `:path_multi` | `did:web:example.com:user:alice` | many |

`:conformant_single` is the conformant shape and what a public server should
run. `:path_multi` gives each account its own DID and key, at the cost of the
federation caveat above.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `PDS_DATA_DIR` | `data` | Directory holding the whole server state. |
| `PDS_HOSTNAME` | `localhost` | Public hostname. Drives the `did:web`. |
| `PDS_PORT` | `4000` | HTTP port. |
| `PDS_MODE` | `conformant_single` | Or `path_multi`. |
| `PDS_HANDLE` | `PDS_HOSTNAME` | Handle published in conformant mode. |
| `PDS_HANDLE_DOMAIN` | `PDS_HANDLE` | Accounts get `alice.<domain>`. |
| `PDS_REGISTRATION` | `closed` | `open` lets anyone create an account. |

An unknown `PDS_MODE` or `PDS_REGISTRATION` raises at boot rather than
defaulting, because a silent default shows up later as something confusing.

## Backup

`data/` is everything. Stop the server and copy it.

SQLite's own backup API gives a consistent database, but not `blobs/`. A
`cp -r` of a running server can tear: a row whose file never landed, or a file
whose row never committed. Neither is fatal, but they disagree until a restart.

**`data/server.secret` matters more than anything else in there.** One HMAC
secret signs tokens for every account; anyone holding it can act as any user on
your server with no trace in the repo. The per-account keys in `keys/` are much
less sensitive, they only let you forge commits for one account, and a forged
commit fails signature verification immediately.

## License

[WTFPL](LICENSE). Do what you want with it.