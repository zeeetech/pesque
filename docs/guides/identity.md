# Identity

How a Pesque server names itself and its accounts, and where that naming stops
working.

## The two modes

`PDS_MODE` decides the topology: whether the server is one account or hosts
many. It is separate from `PDS_IDENTITY`, which decides how each DID is minted
(`did:web` or `did:plc`).

| | `conformant_single` (default) | `path_multi` |
| --- | --- | --- |
| Accounts | exactly one | many |
| Account DID | the server's own | one per account, minted |
| DID method | `did:web` by default, `did:plc` if set | `did:plc` (required) |
| Account handle | `example.com` | `alice.example.com` |
| Federates with the public network | yes | yes |

Both are one code path. `Pesque.Did` is pure and takes the mode as an argument.

## Choosing a mode and a DID method

The mode is the topology; the DID method is how the identity is minted. They
answer different questions, and the method is the one with the sharper trade.

| | `did:web` | `did:plc` |
| --- | --- | --- |
| The document is served by | this server | the PLC directory |
| Depends on | nothing | the PLC directory |
| DID shape | `did:web:<host>` | `did:plc:<hash>` |
| Survives a hostname move | no | yes |
| Official-app sign-up and migration | no | yes |
| Recovery/rotation key | no | yes |
| Best for | a self-sovereign identity bound to a domain you control, with no third party | compatibility with the official app, account migration, and the ecosystem's handle tooling |

The official Bluesky app mints `did:plc` on sign-up and moves a `did:plc` on
migration, so a server whose users arrive through the official app wants
`did:plc`. `did:web` needs no directory and ties the identity to a domain you
already control, at the cost of the DID dying with the domain and not being
movable. Neither is a subset of the other.

**`conformant_single`.** One server, one DID, one account. The account's DID is
the server's own DID, so the signing key is provisioned at boot rather than by
`create_account`.

```bash
PDS_HOSTNAME=example.com PDS_HANDLE=example.com PDS_MODE=conformant_single
# did:web:example.com  ->  at://example.com

PDS_HOSTNAME=example.com PDS_MODE=conformant_single PDS_IDENTITY=plc
# did:plc:...          ->  at://example.com
```

The handle is a bare domain you already own. With `identity = web` the DID is
`did:web:example.com`; with `identity = plc` the server's own `did:plc` is
minted once at boot and persisted to `data/server.identity.json`, so a later
boot reuses it. A second `createAccount` resolves to the same DID and answers
`AccountExists`.

**`path_multi`.** Every account gets its own `did:plc` and signing key.

```bash
PDS_HOSTNAME=pds.example.com PDS_HANDLE_DOMAIN=example.com PDS_MODE=path_multi
# alice -> did:plc:...  at://alice.example.com
# bob   -> did:plc:...  at://bob.example.com
```

Clients send the handle (`alice.example.com`) and Pesque derives the username
(`alice`). The domain half must match `PDS_HANDLE_DOMAIN` exactly, so a lookalike
domain is refused rather than normalized into acceptance. `identity = plc` is
required here: the official client expects a `did:plc` account, and path-based
`did:web` (`did:web:pds.example.com:user:alice`) is not a valid ATProto DID, so
`identity = web` is refused at boot. This is the mode for a small community or a
family server.

## DID documents

Both modes serve the server's identity and one document per account:

| Path | Which |
| --- | --- |
| `/.well-known/did.json` | the server's own DID (`did:web`; 404 when that DID is a `did:plc`) |
| `/.well-known/atproto-did` | the DID for the handle the request arrived under, as `text/plain` |
| `/user/:username/did.json` | the account with that username (`path_multi` only) |

The server's own DID is a `did:web` under every mode except
`conformant_single` with `identity = plc`, where it is the `did:plc` minted at
boot. That `did:plc` resolves at the directory rather than here, so
`/.well-known/did.json` answers 404 instead of publishing a `did:web`-shaped
document that would conflict with the directory's. Under `path_multi` the
server's own DID stays a host-level `did:web` even though its accounts are
`did:plc`, so the document is served here.

The `did:web` document carries the DID as `id`, `alsoKnownAs: ["at://<handle>"]`, a
`#atproto` `Multikey` `verificationMethod`, and an `atproto_pds` service whose
`serviceEndpoint` is always `https://` plus the hostname, with no path and no
port. The port is percent-encoded into the DID, and only for loopback and private
hosts (`did:web:localhost%3A4000`), because the listening port is an internal
detail once a proxy is in front.

## Handle resolution

`com.atproto.identity.resolveHandle` answers which DID this server stores for a
handle it hosts. `/.well-known/atproto-did` answers the same DID as bare
`text/plain` for any stored handle.

A handle on a domain this server does not host is accepted only after it
verifies. `Pesque.HandleResolver` follows the spec's order: DNS TXT at
`_atproto.<handle>` first, then `https://<handle>/.well-known/atproto-did`, and
finally the DID document has to carry `at://<handle>` in `alsoKnownAs`. Without
the last check anyone could point somebody else's handle at their own DID.

Two things follow for the operator: a handle you claim must already be
published, and a domain whose TLD cannot resolve (`local`, `example`, `invalid`,
`localhost`, `onion` and friends) is refused before any lookup.

`describeRepo`'s `handleIsCorrect` is local-only: it checks that this server's
own document and resolver agree, not the network.

### The handle domain is not the PDS host

`PDS_HOSTNAME` is where the server runs; `PDS_HANDLE_DOMAIN` is what handles are
issued under. A server at `pds.example.com` hands out `alice.example.com`
handles. The handle is verified at its own domain (`_atproto.alice.example.com`
or `https://alice.example.com/.well-known/atproto-did`), not at the PDS host, so
the operator publishes a TXT record per handle (or a wildcard) rather than
pointing every handle subdomain at the server.

## did:plc

`PDS_IDENTITY=plc` mints accounts through the PLC directory instead of deriving
them from the hostname. It is the default and only option under `path_multi`,
and it is available under `conformant_single` too: there the server's own
`did:plc` is minted once at boot and persisted to `data/server.identity.json`,
so a later boot reuses it. `PDS_PLC_DIRECTORY` sets the directory (default
`https://plc.directory`).

The DID is minted by the directory at account creation and stored; it never
changes with the hostname, port or domain, which is the point. Each account gets
a rotation key, a second file next to its signing key, and the account's only
recovery path: back up `data/keys` with the rest of the state. A freshly minted
account is registered with the directory before its row is written, so a
submission failure creates no account. The first `conformant_single` boot needs
the directory reachable; once the identity file exists, boot is offline again.
Moving an existing account here is a migration, not a reconfiguration: see the
[Migration guide](migration.md).

## Service auth

`com.atproto.server.getServiceAuth` mints a short-lived ES256K token an account
signs with its own key, so a Relay or a crawling AppView can verify it against
the account's published `#atproto` key. `aud` is the recipient's DID, `lxm`
narrows it to one method, and `exp` is capped at one hour (default 60 seconds).

## Changing hostname or port

**Do not change `PDS_HOSTNAME` or `PDS_PORT` on a server that has accounts.** A
DID is minted once, when the account is created, and stored in the users table.
Lookups match that stored string, because re-deriving it from the current
configuration would turn a port change into a total lockout: every read answers
`RepoNotFound` for an account that plainly exists.

1. Keep the old hostname resolvable, or accept that the old DID is dead.
2. To move the port without moving the DID, keep the old `did:web` percent-encoded
   port reachable. There is no re-issuance path in `did:web`.
3. To move the hostname, you are minting new identities. Use `did:plc` for a DID
   that survives the move.

Changing `PDS_HANDLE_DOMAIN` breaks nothing structurally, but every existing
handle stops resolving to the account that owns it.

## Where federation breaks

**Every record you write is public.** `getRecord`, `listRecords`, `describeRepo`,
`getRepo`, `getLatestCommit`, `subscribeRepos` and `getBlob` answer without a
token, by protocol design. There is no per-repo visibility setting. Treat every
record as published, from the moment it is written.

- **`path_multi` with `identity = web` is refused at boot.** Path-based
  `did:web` (`did:web:example.com:user:alice`) is not a valid ATProto DID, so
  ATProto resolvers ignore it; under `path_multi` accounts are `did:plc` and do
  federate.
- **A `did:web` identity rendered through the public AppView is untested.** It
  needs a real HTTPS hostname and a live account, and it has not been exercised
  against the public deployment. The official app's sign-up mints `did:plc`, so
  a `did:web` account is the less-travelled path.
