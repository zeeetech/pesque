# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

A Personal Data Server for ATProto, written in Elixir.

It does account creation, OAuth (PAR, PKCE, DPoP), legacy sessions, signed
repositories, public reads, blob storage, a firehose, and identity that is
`did:web` by default and `did:plc` when configured. A PDS stores records, signs
commits, hands those commits to anyone who asks, and answers `describeServer`
well enough that a client can decide to talk to it. No feed, no ranking, no
moderation queue.

State is one SQLite file and one directory of blobs. No Postgres, no S3, no
cluster. The protocol primitives (CIDs, DAG-CBOR, the Merkle Search Tree, CAR
archives, TIDs, JWTs, secp256k1) are implemented here rather than pulled in,
because a reference implementation that hides its protocol code behind a
dependency is not showing you anything.

The name sounds like PDS and means "go fish" in Portuguese.

## Run it

Needs Elixir 1.18+ and a C toolchain (the SQLite driver compiles from source).

```bash
mix deps.get
mix phx.server
```

```bash
curl http://localhost:4000/xrpc/_health
```

To host an account:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com
```

Migrations run on boot and `_health` reads the users table, so a server whose
migrations never ran answers `503` instead of a cheerful ok. Docker, releases
and TLS are in the [installation guide](docs/guides/installation.md).

Not implemented yet: `signPlcOperation` and `requestPlcOperationSignature` (the
old PDS signs the move), and granular OAuth consent.

## Guides

- [Installation](docs/guides/installation.md) - local, Docker, release, TLS, first account
- [Identity](docs/guides/identity.md) - DIDs, handles, the two modes, when federation breaks
- [Operations](docs/guides/operations.md) - backup, upgrades, limits, what your data exposes
- [Migration](docs/guides/migration.md) - moving an existing account onto this server
- [Architecture](docs/reference/architecture.md) - module map, the write path, storage layout

The guides are English only. This README is mirrored in
[Português (BR)](README.pt-BR.md).

## Conventions before reading the code

- Everything protocol-shaped is pure: `Pesque.CBOR`, `Pesque.CID`, `Pesque.Mst`,
  `Pesque.Car`, `Pesque.Commit`, `Pesque.Lexicon.Validate` take their inputs as
  arguments, touch no process, and raise or answer rather than log.
- Everything that touches the world lives in `Pesque.RepoStore` (SQL),
  `Pesque.Storage` and `Pesque.Keys` (files), `Pesque.Accounts` (the domain) and
  `PesqueWeb.*` (HTTP).
- One process per repository, holding the entry map and the signing key. Writes
  serialize through it, which is the consistency model a PDS actually needs.
- Domain reasons are tagged tuples. `PesqueWeb.Xrpc.Errors` is the only place one
  becomes a status and a message.

The code is the source of truth. Where these docs disagree with it, the code
wins.

## License

[WTFPL](LICENSE). Do what you want with it.
