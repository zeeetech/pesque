# Contributing

## Setup

Elixir 1.19+ on OTP 28+ and a C toolchain (the SQLite driver compiles from
source). Then:

```bash
mix deps.get
mix phx.server
curl http://localhost:4000/xrpc/_health
```

The flake ships a devshell with the same toolchain: `nix develop`.

## The gate

`mix precommit` before every push. It compiles with `--warnings-as-errors`,
checks formatting, and runs the tests. CI runs the same `mix precommit` on
Elixir 1.20 / OTP 29, so a red check means the local gate was skipped.

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
- The operator surface is driver over verbs: the host-side CLI (`cli/`, Zig)
  implements the `Pesque.Ops` contract and owns the lifecycle; the verbs
  (`Pesque.Cli`) run inside the release through `bin/pesque` and answer tagged
  tuples. The driver reads exit codes (0 ok, 1 domain failure, 2 usage, 3
  driver/env), never verb stdout.

The code is the source of truth. Where these docs disagree with it, the code
wins.

## Commits and pull requests

Conventional Commits with an optional scope (`feat(core):`, `fix(auth):`),
lower-case after the type, no trailing period. One-line subject unless the
change genuinely needs future archaeology. No `Co-Authored-By` or other
generated trailers. Plain prose in bodies and PR text: no marketing
adjectives, no em-dashes.
