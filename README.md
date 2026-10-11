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

One line, then one command:

```bash
curl -fsSL https://github.com/zeeetech/pesque/releases/latest/download/install.sh | sh
cd pesque && pesque setup
```

Run the installer from an empty directory: it verifies and installs the
`pesque` CLI and the compose bundle (Docker + Caddy on the same droplet),
then hands off. Setup asks for the domain clients will use and whether the
server hosts one account or several, pulls the prebuilt image, waits until it
is healthy, creates the first account, and prints the DNS records to add.
After DNS propagates:

```bash
pesque doctor          # federation preflight
pesque account create --handle alice.example.com --email alice@example.com
pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
pesque update          # pull a new image and restart
pesque logs -f         # follow the server logs
```

`account create` and `migrate` prompt for the password with echo off, so it
does not land in your shell history. Flags cover the rest: `--backend
systemd` installs a plain systemd service instead of the compose stack,
`--backend docker` prints the mount-a-conf path for a container you run
yourself, and `--hostname`, `--mode`, `--tag`, `--dir` and `--yes` make the
whole thing scriptable. Raw Docker, releases, TLS without Caddy and every
configuration knob are in the [installation guide](docs/guides/installation.md),
and the flake ships `services.pesque` for NixOS.

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

- **How do I get a server?** The installer: [Deploy it](#deploy-it). Compose
  with Caddy by default, systemd or raw Docker as flags.
- **How do I add another account?**
  `pesque account create --handle alice.example.com --email alice@example.com`;
  it prompts for the password with echo off.
- **How do I back up and restore?** `pesque backup [--out DIR]` runs with the
  server up; `pesque restore ARCHIVE.tar.gz` is cold, stop the server first.
  [Operations](docs/guides/operations.md) has the schedule and the hazards.
- **How do I update?** `pesque update` pulls a new image and restarts.
- **How do I move an account in?**
  `pesque migrate --old-pds https://bsky.social --handle alice.example.com
  --email alice@example.com`; the move is one-way. [Migration](docs/guides/migration.md)
  has the full dance.
- **How do I move an account out?** Not implemented yet: this PDS can't sign
  the move (`signPlcOperation`).
- **Where is the code?** Here. The protocol primitives live in `lib/pesque` on
  purpose; [Architecture](docs/reference/architecture.md) is the map.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before the code: dev setup, the
`mix precommit` gate, and the conventions the tree expects.

## License

[WTFPL](LICENSE). Do what you want with it.
