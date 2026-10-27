# Identity model

Status: implemented.

This supersedes the original proposal. The user-facing explanation is in the
[Identity guide](../guides/identity.md).

## Decisions

- `mode` describes topology only: `single` for one account, `multi` for many.
- The server's host identity is always `did:web:<hostname>`. Boot loads its key;
  it never mints an identity or contacts the PLC directory.
- The account DID method is per account, not server configuration.
- `single` defaults to `did:web`; `pesque account create --identity plc` mints a
  separate `did:plc` account. `--identity web` is also accepted explicitly.
- `multi` always mints `did:plc`; multi-user `did:web` needs subdomain DIDs,
  wildcard DNS and TLS, and remains unsupported.
- Signup and migration are multi-user web flows. Signup mints `did:plc`, while
  migration retains the account's existing `did:plc`.
- `PDS_IDENTITY` and the old `conformant_single` / `path_multi` mode values are
  removed. This is a breaking change; no compatibility aliases are kept.

## Consequences

The server DID and a single PLC account DID are distinct. The account row is the
source of truth for its DID and PLC operation. No `server.identity.json` is
written or read, and backup archives no longer carry that file. The host's
`/.well-known/did.json` is always served for its `did:web` identity.

A legacy `server.identity.json` from an earlier release is unused and may be
removed after upgrading. Existing account rows and their PLC operations are not
changed.
