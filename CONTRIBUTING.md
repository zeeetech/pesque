# Contributing

## Setup

Elixir 1.19+ on OTP 28+ and a C toolchain (the SQLite driver compiles from
source). Then:

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

The flake ships a devshell with the same toolchain: `nix develop`.

## The gate

`mix precommit` before every push. It compiles with `--warnings-as-errors`,
checks formatting, checks the gettext catalog against the compiled call
sites, and runs the tests. CI runs the same `mix precommit` on Elixir
1.20 / OTP 29; changes under `deploy/`, `docker/` or `nix/` additionally
smoke the Compose bundle against the real image and evaluate the NixOS
module. A red check means the local gate was skipped.

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
- The operator surface is verbs plus two thin adapters. The verbs
  (`Pesque.Cli`) run inside the release through `bin/pesque` and answer
  tagged tuples; the entry halts 0 ok, 1 domain failure, 2 usage. The host
  adapters (`deploy/compose/pesque`, `nix/operator.sh`) are POSIX shell:
  they own the backup directory and the cold-restore precondition, forward
  every domain verb to the release, and never re-implement domain logic or
  parse verb output. Lifecycle belongs to Docker Compose and systemd, not to
  Pesque code.

The code is the source of truth. Where these docs disagree with it, the code
wins.

## Commits and pull requests

Conventional Commits with an optional scope (`feat(core):`, `fix(auth):`),
lower-case after the type.
