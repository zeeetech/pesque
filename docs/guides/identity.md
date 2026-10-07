# Identity

How a Pesque server names itself and its accounts, and where that naming stops
working.

## The two modes

`PDS_MODE` is the one decision with consequences you cannot walk back.

| | `conformant_single` (default) | `path_multi` |
| --- | --- | --- |
| Accounts | exactly one | many |
| Account DID | `did:web:example.com` | `did:web:example.com:user:alice` |
| Account handle | `example.com` | `alice.example.com` |
| Federates with the public network | yes | no |

Both are one code path. `Pesque.Did` is pure and takes the mode as an argument.

**`conformant_single`.** One server, one DID, one account. The account's DID is
the server's own DID, so the signing key is provisioned at boot rather than by
`create_account`.

```bash
PDS_HOSTNAME=example.com PDS_HANDLE=example.com PDS_MODE=conformant_single
# did:web:example.com  ->  at://example.com
```

You get the DID shape ATProto resolvers and the public AppView expect, and a
handle that is a bare domain you already own. A second `createAccount` resolves
to the same DID and answers `AccountExists`.

**`path_multi`.** Every account gets its own DID and signing key, derived from a
username under the host.

```bash
PDS_HOSTNAME=pds.example.com PDS_HANDLE_DOMAIN=example.com PDS_MODE=path_multi
# alice -> did:web:pds.example.com:user:alice  at://alice.example.com
# bob   -> did:web:pds.example.com:user:bob    at://bob.example.com
```

Clients send the handle (`alice.example.com`) and Pesque derives the username
(`alice`). The domain half must match `PDS_HANDLE_DOMAIN` exactly, so a lookalike
domain is refused rather than normalized into acceptance. This is the mode for a
small community or a family server; it does not federate, see below.

## DID documents

Both modes serve the server's identity and one document per account:

| Path | Which |
| --- | --- |
| `/.well-known/did.json` | the server |
| `/.well-known/atproto-did` | the DID for the handle the request arrived under, as `text/plain` |
| `/user/:username/did.json` | the account with that username (`path_multi` only) |

The document carries the DID as `id`, `alsoKnownAs: ["at://<handle>"]`, a
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

## did:plc

`PDS_IDENTITY=plc` mints accounts through the PLC directory instead of deriving
them from the hostname. `web` is the default and unchanged. `PDS_IDENTITY=plc`
requires `PDS_MODE=path_multi`, because `conformant_single` serves the account as
the server and the server's own DID is `did:web`. `PDS_PLC_DIRECTORY` sets the
directory (default `https://plc.directory`).

The DID is minted by the directory at account creation and stored; it never
changes with the hostname, port or domain, which is the point. Each account gets
a rotation key, a second file next to its signing key, and the account's only
recovery path: back up `data/keys` with the rest of the state. A freshly minted
account is registered with the directory before its row is written, so a
submission failure creates no account. Moving an existing account here is a
migration, not a reconfiguration: see the [Migration guide](migration.md).

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

- **`path_multi` does not federate with the public Bluesky network.** It uses
  `did:web:example.com:user:alice`. W3C allows a path in a `did:web`, ATProto
  does not, so ATProto resolvers ignore it. Use `conformant_single` or `did:plc`
  to be on the public network.
- **A `did:web` identity rendered through the public AppView is untested.** It
  needs a real HTTPS hostname and a live account, and it has not been exercised
  against the public deployment.
