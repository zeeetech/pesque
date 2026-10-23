# Identity model refactor: one knob, method per account

Status: proposal
Scope: `Pesque.Identity`, `Pesque.Did`, `Pesque.Accounts`, `Pesque.Plc`,
`Pesque.Config`, `config/runtime.exs`, the CLI account verbs, and the web
identity surface.
Non-goal: multi-user `did:web` (see [Deferred](#deferred-multi--didweb)).

## Summary

Today identity is configured on two axes: `PDS_MODE` (topology) and
`PDS_IDENTITY` (DID method). Only three of the four combinations are valid, and
`identity` is dead under one mode and forced under the other, so the config
surface advertises a knob that lies.

This refactor collapses it to **one knob, `PDS_MODE`, and moves the DID method
from server configuration to a per-account decision made at creation time.**

- `PDS_MODE` decides topology only: `single` (one account, the server itself)
  or `multi` (many accounts).
- The server's own DID is **always `did:web:<hostname>`**. It is never minted,
  never persisted to a file, and always served. No boot-time network call.
- PLC is **always available**, never config-gated. Minting happens on demand, at
  account creation or migration.
- A new account's DID method is chosen with `pesque account create --identity
  web|plc`, defaulting per mode.

The user this serves: someone running a single-user server who wants to migrate
an existing official-app account (a `did:plc`) onto it, and who does not want to
reason about two orthogonal identity settings to do it.

## What is wrong today

- `PDS_IDENTITY` is meaningless under `path_multi` (always `plc`) and is the
  only real choice under `conformant_single`. One knob, two behaviours.
- `path_multi + web` is a valid-looking config that is refused at boot. The
  config offers a combination the code rejects.
- Under `conformant_single + plc` the server mints its own `did:plc` **at
  boot**, before any account exists (`Identity.mint_server_identity/0`). A
  server that never creates an account leaves an orphan DID at the directory,
  and the DID is unrecoverable if `data/server.identity.json` is lost.
- The server's own DID is derived from config in two different ways
  (`Identity.did/0`), and `Identity.plc?/0` exists only to answer "did the
  config make the server's DID a plc".

## The new model

Invariants:

1. **The server's own DID is `did:web:<hostname>`, always.** It is the host
   identity. `com.atproto.server.describeServer.did` reports it. This matches
   the reference PDS (`bsky.social` reports `did:web:bsky.social`).
2. **`did:plc` is always available**, gated by nothing. Whether an account is
   web or plc is a property of the account, not of the server.
3. **`PDS_MODE` is the only identity knob.** `single` means exactly one account;
   `multi` means many. Topology, nothing else.
4. **No boot-time identity mint and no server identity file.** `Identity.load!/0`
   loads the `did:web:<hostname>` key and returns.

Account DIDs by mode and origin:

| Mode | Origin | Account DID | Served by |
| --- | --- | --- | --- |
| `single` | `--identity web` (default) | `did:web:<hostname>` | this server |
| `single` | `--identity plc` | minted `did:plc:...` | the directory |
| `single` | migrated | imported `did:plc:...` | the directory |
| `multi` | created | minted `did:plc:...` | the directory |
| `multi` | migrated | imported `did:plc:...` | the directory |

Under `single` with a `web` account, the account DID **equals** the server DID
(one identity, as today). Under `single` with a `plc` account they are two
identities: the server's host `did:web` and the account's `did:plc`.

## Config surface

### Before

```conf
mode = conformant_single | path_multi
identity = web | plc          # forced to plc under path_multi
```

### After

```conf
mode = single | multi
```

- `identity` is removed from `@settings` in `Pesque.Config`, from
  `config/runtime.exs`, and from `Pesque.identity/0`.
- `PDS_IDENTITY` is removed. See [Deprecation](#deprecation).
- `mode` values become `single` / `multi`. The old values
  `conformant_single` / `path_multi` are accepted as aliases for one release
  and normalized to `:single` / `:multi`. `pesque config template` prints the
  new names.

Mode atoms: `Pesque.mode/0` returns `:single | :multi`. This rename is
mechanical (every `:conformant_single` / `:path_multi` pattern match) and is
**separable** from the rest of the refactor: it can ship as its own commit, or
be dropped if the diff noise is unwanted, leaving the atoms and renaming only
the config strings.

### Deprecation

A deployment that still sets `PDS_IDENTITY` would fail boot on the unknown-env
check (`Pesque.Config.validate_env!/0`). To avoid a hard break:

- Add `PDS_IDENTITY` to the accepted-but-deprecated set for one release.
- When present, log a warning: the DID method is now chosen per account
  (`pesque account create --identity`); the setting is ignored.
- Remove the shim in the next major.

`mode` aliases (`conformant_single`, `path_multi`) are accepted silently.

## Account identity selection

`pesque account create --handle H --email E [--identity web|plc]`

Defaults and rules:

- `single`: default `web`. `--identity plc` mints a fresh `did:plc` for the one
  account. `--identity web` is the domain-bound solo identity.
- `multi`: default and only value `plc`. `--identity web` is **refused** with a
  message naming the deferred subdomain mode (see [Deferred](#deferred-multi--didweb)).
- Migration (`pesque migrate`) is unaffected: it always imports a `did:plc`,
  and the flag does not apply.

The XRPC `createAccount` and the HTTP signup page are unchanged: signup stays
`multi`-only and always mints `plc`; `single` accounts are operator-created via
the CLI.

## Module changes

### `Pesque.Identity`

Becomes "the server's own (host) identity", always `did:web`.

- `load!/0` -> `load_web_identity/0` only. Delete the `{mode, identity}` case,
  `load_plc_identity/0`, `mint_server_identity/0`, `cache_server_identity/2`,
  `cache_pub_multibase/1`.
- `did/0` -> `Did.did_for_username(Pesque.mode(), Did.did_host(hostname, port), nil)`,
  which is `did:web:<host>` for both modes. Delete the plc branch.
- Delete `plc?/0` and `server_operation/0`.
- `handle/0`, `did_document/0`, `public_key_multibase/0` unchanged.

### `Pesque.Did`

- `did_for_username/3`: delete the `:path_multi, _host, username` clause. It
  builds `did:web:<host>:user:<username>`, which is not a valid ATProto DID
  (path-based `did:web` is rejected by ATProto resolvers). The only account DIDs
  this function still builds are `web` (which is the host form) and the host
  identity itself. Rename mode atoms.
- `handle_for_username/3`: unchanged except the mode atom rename.
- `did_document/2`, `plc_document/1`: unchanged.

### `Pesque.Accounts`

- `create_account/4`: `opts[:identity]` is `:web | :plc`, defaulted from the
  mode (`single` -> `:web`, `multi` -> `:plc`).
- `identity_for/1` -> `identity_for/2` (handle, method). Returns
  `%{mode, method, handle, username, did}`:
  - `:web`: `did` derived (`did:web:<host>` under `single`).
  - `:plc`: `did` is `nil`; the DID is minted in `claim_account/2`.
- `single_account/2`: `web` -> DID `Identity.did()`, username `nil`; `plc` ->
  handle is the bare handle domain, username `nil`, DID `nil`.
- `path_multi_account/1`: always `plc`, DID `nil`. This removes the current
  placeholder `did:web:...:user:...` that `Plc.mint` overwrites.
- `claim_account/2` (identity, method): `:web` -> `claim_key/1`; `:plc` ->
  `Pesque.Plc.mint/1`. Delete the `Identity.server_operation/0` carry.
- `check_available/2`: unchanged logic, but it must not compare a `nil` DID
  (the plc case) against the users table; compare by handle, and by DID only
  when present.
- `handle_available?/1` and `handle_suggestions/2`: call `identity_for/2` with
  the mode default method.
- `document/1`: unchanged (already branches on the stored DID prefix).

### `Pesque.Plc`

- Delete `enabled?/0`. PLC is always available.
- Everything else (`mint/1`, `update_handle/2`, `verify_pds/1`,
  `submit_operation/2`, `recommended_credentials/1`) unchanged.

### `Pesque` (top-level)

- Delete `identity/0`.

### `config/runtime.exs`

- Delete the `identity` parsing block and `config :pesque, identity:`.
- `mode`: accept `single`/`multi`, plus `conformant_single`/`path_multi`
  aliases.
- `handle_domain` default unchanged (`single` -> the bare `handle`, `multi` ->
  `hostname`).
- Add the `PDS_IDENTITY` deprecation warning.

### `Pesque.Config`

- Remove the `identity` entry from `@settings`.
- Update the `mode` prose to the new values.

### `Pesque.Storage`

- Delete `server_identity_path/0`, `read_server_identity/0`,
  `write_server_identity/1`. Nothing writes or reads a server identity file
  anymore.

### CLI `pesque account create`

- Add `--identity web|plc` (`identity: :string`).
- Validate against the mode (`web` refused under `multi`), then pass to
  `Accounts.create_account/4` as `identity: method`.
- Update `@usage`.

## Web surface

### `PesqueWeb.Xrpc.IdentityController`

- `did_document/2`: always serve `Identity.did_document/0`. Delete the
  `Identity.plc?()` 404 branch. `/.well-known/did.json` is the host document
  under every mode and every account method.
- `atproto_did/2`, `user_did_document/2`, `resolve_handle/2`: unchanged (they
  already answer the stored DID per handle).

### `PesqueWeb.Plugs.Admin`

This is a correctness change, not cosmetic. `operator?/1` currently accepts
`Identity.did()`. Under the new model `Identity.did()` is `did:web:<host>`,
which **no account holds** under `single` with a `plc` account (the operator's
session DID is the `did:plc`). The default operator set must become:

- `single`: the single account's DID when it exists, else the host DID.
- `multi`: the host DID (unreachable, as today) plus any configured
  `admin_dids`.

### `Pesque.Doctor`

- `config_check/0`: drop `identity=` from the detail string.
- `did_document_check/1`: always check the local
  `/.well-known/did.json`. Optionally add a second check that resolves the
  single account's DID (plc or web) to catch a directory mismatch; that is an
  account-identity check, not a server-identity one.

### `PesqueWeb.PageController` / `PageHTML`

- `render_landing/1`: drop the `identity:` assign, or set it from the single
  account's method. `PageHTML.identity/1` and the `accounts/1` clauses
  (`:conformant_single` -> `:single`, etc.) follow the mode rename.

## State and data

- No data migration. The account row already carries `did` and `plc_operation`;
  that is the authoritative record of a `plc` identity. Nothing needs the
  server identity file.
- An existing `conformant_single + plc` deployment: the account keeps its
  `did:plc`; the server gains a new `did:web:<host>` host identity. The
  operator's `admin_dids` default moves from the old server DID (the plc) to
  the account DID, which is the same value. `describeServer.did` changes from
  the plc to `did:web:<host>`; see [Risks](#behavior-changes-and-risks).
- `data/server.identity.json`, if present from an old deployment, becomes
  unused. It can be deleted; nothing reads it.

## What gets deleted

- `Pesque.Config`: the `identity` setting.
- `config/runtime.exs`: the identity parse block.
- `Pesque.identity/0`.
- `Pesque.Identity`: `load_plc_identity/0`, `mint_server_identity/0`,
  `cache_server_identity/2`, `plc?/0`, `server_operation/0`, the plc branch of
  `did/0`.
- `Pesque.Plc.enabled?/0`.
- `Pesque.Storage`: the server identity file read/write/path.
- `Pesque.Did.did_for_username/3`: the `:path_multi` username clause (the
  invalid path-based DID builder).
- `IdentityController.did_document/2`: the 404 branch.
- `Accounts`: the `Identity.server_operation/0` carry and the
  `Plc.enabled?()` branch in `claim_account/1`.

## Deferred: multi + did:web

Multi-user `did:web` is possible, but not as a flag: it requires a
**subdomain DID** per account (`did:web:alice.example.com`, document at
`https://alice.example.com/.well-known/did.json`). That is a distinct topology:

- wildcard DNS (`*.<handle_domain>` -> server) and wildcard TLS.
- the handle becomes the DID authority (no foreign handles, no handle moves).
- cannot hold migrated or `plc` accounts.
- no official-app sign-up.

It is out of scope here. `multi --identity web` is refused with a message
pointing at this, so the door is left visibly open rather than silently.

## Behavior changes and risks

1. **`describeServer.did` under `single + plc` changes** from the account's
   `did:plc` to `did:web:<host>`. This is the intended model (the server's own
   DID is its host identity) and matches the reference PDS, but it is a wire
   change. Clients that cached the old value should re-read it.
2. **Host document `alsoKnownAs` overlap under `single`.** The host
   `did:web:<host>` document claims `at://<hostname>`, and under `single` the
   account's handle is the bare handle domain, which defaults to the hostname.
   When the account is `web` the two are the same DID, so there is no overlap.
   When the account is `plc`, the host document and the account's document both
   claim the same handle string. This is cosmetic: handle resolution
   (`/.well-known/atproto-did`, DNS TXT) returns the account's DID, and
   `HandleResolver.verify/2` checks the account's document, never the host's.
   Optional cleanup: omit `alsoKnownAs` from the host document when a separate
   account owns the handle. Deferred; low priority.
3. **`admin_dids` default** must follow the single account's DID, not the host
   DID (see `Admin` above). Getting this wrong locks the operator out of admin
   endpoints on `single + plc`.
4. **No more orphan DIDs at boot.** The boot-time mint is gone, so a server
   that never creates an account never touches the directory.
5. **Mode value rename** breaks configs that pin `conformant_single` /
   `path_multi` only if the aliases are dropped. Keep the aliases.

## Test plan

- `Pesque.Did`: remove the `:path_multi` username cases; assert
  `did_for_username/3` no longer builds a path DID.
- `Pesque.Identity`: `load!/0` never touches the network; `did/0` is
  `did:web:<host>` in both modes.
- `Pesque.Accounts.create_account/4`:
  - `single` + `web` -> DID is the host `did:web`, key is the boot key, no
    directory call.
  - `single` + `plc` -> DID is minted, row carries `plc_operation`, no file
    written.
  - `multi` + default -> minted `did:plc`.
  - `multi` + `web` -> refused.
- `IdentityController.did_document/2`: serves the host document in both modes
  and for both account methods.
- `Plugs.Admin`: `single + plc` operator (the account DID) is admitted;
  a stranger is refused.
- Migration: `single + plc` import still completes end to end.
- Config: `mode = single|multi` parse; `conformant_single|path_multi` aliases;
  `PDS_IDENTITY` warns and is ignored.

## Docs to update

- `docs/guides/identity.md`: rewrite the "two modes" and "choosing a mode and a
  DID method" sections around one knob and a per-account method; drop the
  `identity = plc` single-server boot-mint prose.
- `README.md` / `README.pt-BR.md`: the `PDS_MODE` / `PDS_IDENTITY` description
  and the sign-up note.
- `pesque.conf.example`: regenerate from the template.
- `docs/reference/architecture.md`: the identity module map.
- `CHANGELOG.md`: a breaking-change entry (`PDS_IDENTITY` removed, `PDS_MODE`
  values renamed, account identity via `--identity`).

## Rollout

1. Mode atoms + config values (`single`/`multi`) with aliases; `PDS_IDENTITY`
   deprecation warning. No behavior change.
2. Move the `single + plc` mint from boot to `claim_account/2`; add
   `--identity web|plc`; drop the server identity file.
3. Delete `Identity.plc?/0` and the 404 branch; always serve the host document.
4. Fix `admin_dids` default and `describeServer.did`.
5. Docs and changelog.

## Open decisions

1. **Mode rename now or later?** Steps 1 (rename) and 2-4 (behavior) can ship
   separately. Renaming touches many pattern matches for no behavior gain.
2. **Host `alsoKnownAs` under `single`.** Accept the cosmetic overlap, or omit
   the handle from the host document when an account owns it (needs `Identity`
   to consult `Accounts`).
3. **`describeServer.did` change.** Confirm no consumer of this PDS depends on
   it being the account DID under `single + plc`.
