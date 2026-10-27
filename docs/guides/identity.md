# Identity

How a Pesque server names itself and its accounts, and where that naming stops
working.

## One server identity, two account modes

The server's own DID is always `did:web:<hostname>`. It is derived from the
hostname, its key is loaded at boot, and its document is always served at
`/.well-known/did.json`. The server identity does not depend on how accounts
are created.

`PDS_MODE` decides only the account topology:

| | `single` (default) | `multi` |
| --- | --- | --- |
| Accounts | exactly one | many |
| Account handle | bare handle domain | `alice.example.com` |
| Default account DID | server's `did:web` | minted `did:plc` |
| Signup and migration pages | no | yes |

There is no server-wide DID-method setting. A multi account is always `did:plc`;
path-based `did:web` is not a valid ATProto DID. In single mode, account creation
can choose `did:web` or `did:plc`.

## Choosing the account DID method

The CLI `pesque account create` chooses the method for a single account:

```sh
# Default in single mode: use the server's did:web.
pesque account create --handle example.com --email alice@example.com

# Or mint a separate did:plc account for the same handle.
pesque account create --handle example.com --email alice@example.com --identity plc
```

The default is `web` in `single` mode and `plc` in `multi` mode. `--identity
web` is rejected under `multi`. The browser signup and migration flows are
multi-user flows, so they always create or import a `did:plc` account.

`did:web` needs no directory and ties the identity to a domain you control, at
the cost of the DID depending on that domain. `did:plc` is compatible with the
official app and account migration, and survives a hostname move, but depends on
the PLC directory and has a rotation key that must be backed up with the data
directory.

## Single mode

A single server has one account, with the bare handle domain. By default that
account shares the host's `did:web` and signing key:

```sh
PDS_HOSTNAME=example.com PDS_MODE=single
# server DID and account DID: did:web:example.com
# account handle: example.com
```

To use a `did:plc` account instead, create it with `--identity plc`. The server
still has `did:web:example.com`; the account has a separate DID minted at
creation. No DID is minted at server boot and there is no server identity file.
The account row stores the PLC operation.

## Multi mode

Every account has a handle under the configured handle domain and a separately
minted `did:plc`:

```sh
PDS_HOSTNAME=pds.example.com PDS_HANDLE_DOMAIN=example.com PDS_MODE=multi
# alice -> did:plc:...  at://alice.example.com
# bob   -> did:plc:...  at://bob.example.com
```

A handle must be exactly one label under the configured domain; a lookalike
domain is refused. Multi-user `did:web` is not supported. It would require a
separate subdomain DID and document per account, plus wildcard DNS and TLS.

## DID documents and handle resolution

| Path | Which identity |
| --- | --- |
| `/.well-known/did.json` | Always the server's host `did:web` |
| `/.well-known/atproto-did` | The DID for the handle on the request host |
| `/user/:username/did.json` | Multi account DID document (legacy route; PLC accounts resolve at the directory) |

`com.atproto.identity.resolveHandle` and `/.well-known/atproto-did` answer the
DID stored for a local handle. A foreign handle is accepted only after it
resolves to the account DID and the DID document claims that handle in
`alsoKnownAs`.

`did:web` documents carry the DID as `id`, an `alsoKnownAs` handle, a `#atproto`
`Multikey` verification method, and an `atproto_pds` service whose endpoint is
the advertised server URL. A port is percent-encoded into the DID only for
loopback and private hosts, because the listening port is an internal detail
when a proxy is in front.

## PLC identities and migration

PLC is available whenever an account needs it; it is not enabled by server
configuration. `PDS_PLC_DIRECTORY` chooses the directory (default
`https://plc.directory`). New PLC accounts are minted at account creation.
Migrated accounts retain their existing `did:plc`.

A PLC account has a signing key and a rotation key under `data/keys`. Back up
the entire data directory. The directory registers the DID before Pesque writes
the account row, so a failed create can leave an unused DID at the directory,
but cannot leave an account whose DID does not resolve.

## Changing hostname or handle domain

Do not change `PDS_HOSTNAME` on a server with accounts. A `did:web` account is
bound to its hostname; a `did:plc` account retains its DID but its published PDS
endpoint still needs to match the server configuration. Changing
`PDS_HANDLE_DOMAIN` does not rewrite stored handles, so existing handles stop
resolving unless their records continue to be served.

## Where federation breaks

Every record is public by protocol design. Treat records, blobs, commits and
firehose events as published.

- `did:web` requires a public HTTPS document at the hostname. A server reachable
  only over plain HTTP does not federate.
- A PLC account's DID document is served by the directory, not by Pesque.
- `multi` accounts are `did:plc`; did:web subdomain accounts are not supported.
