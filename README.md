# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

A Personal Data Server for ATProto, written in Elixir.

It does account creation, OAuth (PAR, PKCE, DPoP), legacy sessions, signed
repositories, public reads, blob storage, a firehose, and `did:web` server
identity with account identities chosen at creation. A PDS stores records,
signs commits, hands those commits to anyone who asks, and answers
`describeServer` well enough that a client can decide to talk to it. No
feed, no ranking, no moderation queue.

State is one SQLite file and one directory of blobs. No Postgres, no S3, no
cluster. The protocol primitives (CIDs, DAG-CBOR, the Merkle Search Tree,
CAR archives, TIDs, JWTs, secp256k1) are implemented here rather than pulled
in, because a reference implementation that hides its protocol code behind a
dependency is not showing you anything.

The name sounds like PDS and means "go fish" in Portuguese.

## Deploy it

On any Docker host, get the Compose bundle from the
[latest release](https://github.com/zeeetech/pesque/releases/latest) (verify
it against `SHA256SUMS`), then:

```bash
tar -xzf pesque-compose-<version>.tar.gz && cd pesque
./pesque init                        # writes pesque.conf, creates backups/
$EDITOR pesque.conf                  # the public hostname clients will use
docker compose up --detach --wait
./pesque account create --handle alice.example.com --email alice@example.com
```

On NixOS, the flake's module runs the same image under systemd:
[Installation](docs/installation.md#nixos).

There is no setup wizard and no TLS in the box: the reverse proxy and its
certificates are the operator's job. Point the proxy at the published port
(`127.0.0.1:4000` by default) and add the DNS records yourself. Lifecycle is
Docker Compose (or `systemctl`); the `pesque` command, runs everything that touches the data directly, and updates are manual.

After the first account:

```bash
./pesque doctor          # federation preflight
./pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
./pesque backup          # live-safe; restore is cold
./pesque account list
```

`account create` and `migrate` prompt for the password with echo off, or
read it from stdin (`echo secret | ./pesque ...`), so it never lands in your
shell history or the environment.

## Run it from source

Needs Elixir 1.19+ on OTP 28+ and a C toolchain (the SQLite driver compiles
from source).

```bash
mix deps.get
mix phx.server
curl http://localhost:4000/xrpc/_health
```

To host an account:

```bash
mix run -e 'Pesque.Cli.main()' account create --handle alice.example.com --email alice@example.com
```

The verb boots the whole application, endpoint included, runs, and exits.
Migrations run on boot and `_health` reads the users table, so a server
whose migrations never ran answers `503` instead of a cheerful ok.

## Guides

- [Installation](docs/installation.md) - single or multi, Docker, NixOS, the
  TLS proxy, configuration, verification
- [Operations](docs/operations.md) - backup, accounts, moving an account in,
  upgrades, limits, what your data exposes

The guides are English only. This README is mirrored in
[Português (BR)](README.pt-BR.md).

## Common questions

- **How do I get a server?** The Compose bundle and four commands:
  [Deploy it](#deploy-it). One container; the TLS proxy is yours.
- **How do I add another account?**
  `./pesque account create --handle alice.example.com --email alice@example.com`;
  it prompts for the password with echo off. Later accounts need an invite
  code unless registration is open.
- **How do I back up and restore?** `pesque backup` runs with the server up;
  `pesque restore ARCHIVE_NAME` is cold, stop the server first.
  [Operations](docs/operations.md#backup-and-restore) has the schedule and
  the hazards.
- **How do I update?** Manually. Docker: unpack a newer bundle over the same
  directory and `docker compose up --detach --wait`. NixOS: raise the pinned
  image tag and `nixos-rebuild switch`.
- **How do I move an account in?**
  `./pesque migrate --old-pds https://bsky.social --handle alice.example.com
  --email alice@example.com`; the move is one-way and the new server must be
  `multi`. [Operations](docs/operations.md#moving-an-account-in) has the
  full dance.
- **How do I move an account out?** The destination PDS runs the move; this
  server signs the identity step (`signPlcOperation`), and the confirmation
  code reaches you, the operator, through the log or
  `pesque account plc-token`, not an inbox.
  [Operations](docs/operations.md#accounts).
- **How do I accept records for another app's collection?** You already do.
  A collection this server ships no lexicon for is stored as it came and
  reported `validationStatus: "unknown"`, the same answer the reference PDS
  gives. There is nothing to install.
- **Where is the code?** Here. The protocol primitives live in `lib/pesque`
  on purpose; [CONTRIBUTING.md](CONTRIBUTING.md) maps the layers.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before the code: dev setup, the
`mix precommit` gate, and the conventions the tree expects.

## License

[WTFPL](LICENSE). Do what you want with it.
