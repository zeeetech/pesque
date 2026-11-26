# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

An ATProto Personal Data Server in Elixir with account creation, OAuth (PAR,
PKCE, DPoP), legacy sessions, signed repositories, public reads, blobs, and a firehose.

The name sounds like PDS and means “go fish” in Portuguese.

State is one SQLite database and a blob directory; there is no cluster. Pesque
fits a few accounts or a small community, not aggressive multi-tenant hosting.
No admin UI, setup wizard, bundled TLS, or Caddy: operators provide a proxy and
certificates.

## Deploy with Docker Compose

Download the [latest release](https://github.com/zeeetech/pesque/releases/latest)
with its `SHA256SUMS` file, verify it, then start the server:

```bash
sha256sum -c SHA256SUMS
tar -xzf pesque-compose-<version>.tar.gz && cd pesque
./pesque init
$EDITOR pesque.conf                  # set the public hostname and URL scheme
docker compose up --detach --wait
./pesque account create --handle pds.example.com --email alice@example.com
```

This creates the first account in the default `single` mode. Registration is
closed by default: browser signups need an invite unless it is opened, while
operators can create accounts directly with the CLI. Browser signup and account
migration require `multi`. A configurable `crawler` announces the
server to relays; see the [installation guide](docs/installation.md).

The NixOS flake module runs the same image under systemd: [installation](docs/installation.md#nixos).

## Operate it

The Compose bundle's `./pesque` command provides operator tasks:

```bash
./pesque doctor
./pesque backup
./pesque migrate --old-pds https://bsky.social \
  --handle alice.example.com --email alice@example.com
```

Migration requires `multi`. [Operations](docs/operations.md) covers accounts,
backups, migration, upgrades, and limits; [Installation](docs/installation.md)
covers configuration, TLS proxy setup, account modes, and verification.

## Run from source

For development, not a supported deployment path. Requires Elixir 1.19+ on
OTP 28+ and a C toolchain:

```bash
mix deps.get
cat > pesque.conf <<'EOF'
url_scheme = http
hostname = localhost
port = 4000
data_dir = data
EOF
mix run --no-start -e 'Enum.each(Pesque.Config.source_config!(), fn {k, v} -> Application.put_env(:pesque, k, v) end); Pesque.Release.prepare()'
mix phx.server
curl http://localhost:4000/xrpc/_health
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and the
`mix precommit` gate.

## License

[WTFPL](LICENSE).
