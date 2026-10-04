# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

A minimal, self-hosted ATProto Personal Data Server written in Elixir. The name sounds like PDS and means "go fish" in Portuguese, which felt right for a server that feeds the firehose.

One SQLite file holds the whole server. The reference PDS (TypeScript, PostgreSQL, S3, Node) is built for scale-out hosting. Pesque targets the other end: a handful of accounts, tens of megabytes of idle memory, and a data directory you can back up with `cp`.

CIDs, the Merkle Search Tree, CAR archives, and JWTs are hand-built, because that is where the protocol actually lives. Dependencies stay minimal: Phoenix (API-only), Bandit, Ecto with SQLite.

## Two things to know before you put data on a server

**Every local repo is world-readable.** `getRecord`, `listRecords`, `getRepo`, `getLatestCommit`, `describeRepo`, and `subscribeRepos` are public by protocol design and answer without a token. There is no per-repo visibility setting, and adding one would break the protocol: the point of a PDS is that a repo is fetchable by anyone who knows its DID. Treat everything you write as published.

**`:path_multi` does not federate to the public Bluesky network.** Accounts get DIDs like `did:web:example.com:user:alice`. W3C's did:web method allows path-based DIDs, but ATProto restricts did:web to hostname level only, so ATProto resolvers will not follow them. This is the deliberate price of not depending on the PLC directory, which Bluesky operates: Pesque stays self-contained and never needs someone else's infrastructure to resolve an identity. Run `:conformant_single` if you want to be on the public network.

One narrower caveat: whether the public Bluesky AppView renders a `did:web` identity at all is **untested**. That needs a stable public HTTPS hostname and a live account, and it is deferred. Assume nothing in either direction.

## What is not implemented

So you do not plan around it:

- **Blobs.** No `uploadBlob` or `getBlob`. Records with image or video embeds will not work.
- **Lexicon validation.** `Pesque.Lexicon` is a codec, converting `$link` and `$bytes` between XRPC JSON and CBOR. It does not check a record against its Lexicon, so a malformed record from a non-reference client is stored as given.
- **OAuth.** Sessions are legacy HS256 bearer tokens: no PAR, no DPoP, no scopes, no client IDs.
- **Multi-server federation and `did:plc`.** Two Pesque instances do not sync.
- **AppView.** Pesque serves a PDS, not a feed.

Everything else is there: repo storage (MST, commits, CAR export), the read and write XRPC endpoints, per-account secp256k1 signing keys, `did:web` documents, handle resolution, and the firehose.

## Running it

Needs Elixir 1.18 or later and a C toolchain for the SQLite driver.

```bash
mix deps.get
mix phx.server
```

Migrations run on boot. The server answers at `http://localhost:4000`:

```bash
curl http://localhost:4000/xrpc/_health
```

With no configuration, Pesque runs in `:conformant_single` on `localhost:4000` and writes to `./data`.

## Creating an account

Registration is closed by default, so `createAccount` over HTTP answers:

```json
{"error":"InvalidRequest","message":"registration is closed; accounts are provisioned by the operator"}
```

Provision from the host instead:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com --password secret123
```

```plain
created alice.example.com (did:web:example.com)
```

This boots the whole application, so the port must be free while it runs: stop the server first, or provision from a second shell with a different `PDS_PORT`.

Set `PDS_REGISTRATION=open` and `createAccount` becomes an open endpoint. Only do that where you want strangers holding accounts.

A handle is `<username>.<handle domain>`, so `alice.example.com` when `PDS_HANDLE_DOMAIN=example.com`. The domain is your own DNS, so world collisions are yours to manage. Local ones cannot happen: two concurrent `createAccount` calls for one handle produce exactly one account.

## Modes

| Mode | DID | DID document | Accounts |
| --- | --- | --- | --- |
| `:conformant_single` (default) | `did:web:example.com` | `/.well-known/did.json` | one |
| `:path_multi` | `did:web:example.com:user:alice` | `/user/alice/did.json` | many |

`:conformant_single` is the conformant shape: one DID for the server, at hostname level, which is what a public server should run. It holds exactly one account, and that account is the server itself.

`:path_multi` gives each account its own DID and signing key, at the cost of the federation deviation above. Use it for a community instance, a private group, or a homelab where you control resolution yourself.

did:web percent-encodes a non-default port, so port 3000 publishes `did:web:example.com%3A3000:user:alice`. A production DID carries no port.

## Configuration

All read from the environment at boot. An unknown `PDS_MODE` or `PDS_REGISTRATION` raises rather than falling back, because a silent fallback surfaces later as a confusing failure.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PDS_DATA_DIR` | `data` (`tmp/test` under `MIX_ENV=test`) | Directory holding the entire server state. |
| `PDS_HOSTNAME` | `localhost` | Public hostname. Drives the `did:web`. |
| `PDS_PORT` | `4000` | HTTP listen port. |
| `PDS_MODE` | `conformant_single` | `conformant_single` or `path_multi`. Anything else raises at boot. |
| `PDS_HANDLE` | equals `PDS_HOSTNAME` | The handle `:conformant_single` publishes. Ignored in `:path_multi`. |
| `PDS_HANDLE_DOMAIN` | equals `PDS_HANDLE` | Domain accounts get: `alice.<handle domain>`. |
| `PDS_REGISTRATION` | `closed` | `open` lets anyone call `createAccount`. Anything else raises at boot. |

The database pool is fixed at 4 and not configurable. The endpoint advertises `https` on `PDS_HOSTNAME`, so put a TLS-terminating proxy (Caddy or nginx) in front of anything reachable from the internet.

## Backups, and the one file that matters

`data/` is the entire server state. Copy the directory and you have copied the server: the SQLite database with its `-wal` and `-shm` sidecars, `keys/` with one signing key per account (0600, in a 0700 directory), and `server.secret`.

Back it up by copying the directory while the server is stopped, or with SQLite's backup API if you need a consistent snapshot of a running one.

**`data/server.secret` is the crown jewel, not the signing keys.** One HMAC secret signs access and refresh tokens for *every* account. Anyone holding it can mint a valid token for any DID this server hosts and act as any user, silently, leaving no trace in the repo. The per-account keys in `data/keys/` are far less sensitive: they only let you forge commits for one account, and a forged commit fails signature verification the moment anyone checks it. Lose a signing key and that one identity is visibly broken. Leak the server secret and the whole server is open with nobody able to tell.

## Docker

The image sets `PDS_DATA_DIR=/data` and `PDS_PORT=4000`, and declares `VOLUME /data`.

```bash
docker build -t pesque .
docker run -d \
  --name pesque \
  -p 4000:4000 \
  -v pesque-data:/data \
  -e PDS_HOSTNAME=pds.example.com \
  pesque
```

For a real deployment, put the container behind a TLS-terminating proxy and set `PDS_HOSTNAME` to the public hostname, or the advertised URLs and the `did:web` will name `localhost`.

## The did:web tradeoff

Identity comes from `did:web`, not the PLC directory, so your DID document is a JSON file served from your own domain and the server stays self-contained.

The cost: your identity is only as stable as your control of the domain and the key files on disk. If the domain lapses or `data/keys/` is lost, the identity goes with it. For a self-hosted server on a domain you control that is usually the right trade, but know what you are accepting.