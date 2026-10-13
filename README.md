# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
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

## Deploy it

Install the CLI, write a conf, bring the server up:

```bash
curl -fsSL https://github.com/zeeetech/pesque/releases/latest/download/install.sh | sh
pesque config template --out pesque.conf
```

Edit `pesque.conf` with the domain clients will use, then:

```bash
pesque up
pesque account create --handle alice.example.com --email alice@example.com
```

The installer verifies and installs the `pesque` CLI, that's all. There is no
setup wizard and no TLS in the box: the reverse proxy and its certificates are
the operator's job. Point your proxy at the published port (`127.0.0.1:4000` by
default) and add the DNS records yourself.

The CLI speaks to one of two backends, picked with `--backend docker|systemd`
or `PESQUE_BACKEND`. `docker` (default) creates and owns one container: `up`
runs it if absent and starts it otherwise, `down` stops it with the data kept,
`update [tag]` pulls a new image and recreates the container with the same
settings. `systemd` runs the release as a native systemd service and the unit
owns the lifecycle, so `up`, `down`, `restart` and `update` are no-ops there;
NixOS is detected as systemd. Updates are manual only, there is no auto-update.

After the first account:

```bash
pesque doctor          # federation preflight
pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
pesque update          # pull a new image and recreate the container
pesque logs -f         # follow the server logs
```

`account create` and `migrate` prompt for the password with echo off, or read
it from stdin (`echo secret | pesque ...`), so it never lands in your shell
history or the environment. Raw Docker, releases, TLS and every configuration
knob are in the [installation guide](docs/guides/installation.md).

## Run it from source

Needs Elixir 1.19+ on OTP 28+ and a C toolchain (the SQLite driver compiles from
source).

```bash
mix deps.get
mix phx.server
curl http://localhost:4000/xrpc/_health
```

To host an account:

```bash
mix pesque.account create --handle alice.example.com --email alice@example.com
```

`mix pesque.create_account` is the same task under the old name, kept so older
guides and scripts keep working.

Signing up needs `PDS_MODE=path_multi`, which mints `did:plc` accounts and
submits them to the public PLC directory. To sign up or migrate in development
without minting a real DID there, add `PDS_PLC_LOCAL=true`: the operations are
kept under `data_dir` instead. The setting is refused outside the dev and test
environments.

Migrations run on boot and `_health` reads the users table, so a server whose
migrations never ran answers `503` instead of a cheerful ok.

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

## Common questions

- **How do I get a server?** The installer and three commands:
  [Deploy it](#deploy-it). One Docker container or a systemd service; the TLS
  proxy is yours.
- **How do I add another account?**
  `pesque account create --handle alice.example.com --email alice@example.com`;
  it prompts for the password with echo off.
- **How do I back up and restore?** `pesque backup [--out DIR]` runs with the
  server up; `pesque restore ARCHIVE.tar.gz` is cold, stop the server first.
  [Operations](docs/guides/operations.md) has the schedule and the hazards.
- **How do I update?** `pesque update` pulls a new image and recreates the
  container (docker backend, manual only); on systemd you upgrade the release
  yourself.
- **How do I move an account in?**
  `pesque migrate --old-pds https://bsky.social --handle alice.example.com
  --email alice@example.com`; the move is one-way. [Migration](docs/guides/migration.md)
  has the full dance.
- **How do I move an account out?** Not implemented yet: this PDS can't sign
  the move (`signPlcOperation`).
- **How do I accept records for another app's collection?** You already do. A
  collection this server ships no lexicon for is stored as it came and reported
  `validationStatus: "unknown"`, the same answer the reference PDS gives; writes
  are only refused when they break a lexicon this server ships
  (`priv/lexicons`). `pesque lexicon add --from https://github.com/org/lexicons`
  installs more documents into `data/lexicons` for resolution (OAuth permission
  sets), not for enforcement; `com.atproto` files are skipped so a third party
  cannot shadow the vendored set.
- **Where is the code?** Here. The protocol primitives live in `lib/pesque` on
  purpose; [Architecture](docs/reference/architecture.md) is the map.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before the code: dev setup, the
`mix precommit` gate, and the conventions the tree expects.

## License

[WTFPL](LICENSE). Do what you want with it.
