# Architecture

How Pesque is put together, for reading rather than for deploying. Three parts:
the shape of the code, the write path end to end, and the protocol primitives.

## The shape

Three layers, and the dependency direction only ever points downward.

**Pure protocol core.** No process, no database, no configuration, no clock
beyond what is passed in. Every function takes what it needs and returns a value
or `{:error, reason}`.

```
lib/pesque/cbor.ex              DAG-CBOR encode and decode
lib/pesque/cid.ex               CIDv1, dag-cbor and raw codecs
lib/pesque/varint.ex            LEB128
lib/pesque/base32.ex            RFC 4648 base32, lowercase, no padding
lib/pesque/base58.ex            base58btc, for multibase keys
lib/pesque/car.ex               CAR v1 writer and stream
lib/pesque/mst.ex               Merkle Search Tree, build and incremental update
lib/pesque/tid.ex               timestamp identifiers
lib/pesque/secp256k1.ex         keypairs, compressed points, low-S ECDSA
lib/pesque/token.ex             HS256 JWT
lib/pesque/lexicon.ex           $link and $bytes conversion
lib/pesque/lexicon/validate.ex  record validation, pure and total
lib/pesque/lexicon/registry.ex  lexicon index in :persistent_term
lib/pesque/did.ex               DID and handle derivation, DID documents
lib/pesque/commit.ex            the commit protocol, and the frames
lib/pesque/event_frames.ex      the #identity and #account frames
lib/pesque/record.ex            what a record must satisfy before commit
lib/pesque/grapheme.ex          UAX #29 segmentation
lib/pesque/plc/operation.ex     PLC operations: construction, signing, the DID
lib/pesque/oauth/jwt.ex         ES256 JWS and the RFC 7638 thumbprint
lib/pesque/oauth/dpop.ex        DPoP proof verification
lib/pesque/oauth/scopes.ex      which scopes are grantable
```

`Pesque.Did` is why this layer exists: it takes the mode, hostname, handle
domain, port and public key as arguments, so both identity modes are testable
without a server running.

**Imperative shell.** Everything that touches the world.

```
lib/pesque/repo.ex              the Ecto repo
lib/pesque/repo_store.ex        all SQL, and only SQL
lib/pesque/repo_store/*.ex      schemas
lib/pesque/storage.ex           data directory, permissions, server secret
lib/pesque/release.ex           migration runner
lib/pesque/keys.ex              one signing key file per DID
lib/pesque/secret.ex            the HMAC secret, cached in :persistent_term
lib/pesque/blob.ex              blob bytes, gated on the blobs row
lib/pesque/accounts.ex          account lifecycle, sessions, write authorization
lib/pesque/identity.ex          the server's own identity
lib/pesque/repo_server.ex       one process per repository
lib/pesque/repo_supervisor.ex   finds and starts them
lib/pesque/events.ex            the firehose log outside a commit
lib/pesque/event_reaper.ex      daily retention sweeps
lib/pesque/rate_limit.ex        fixed-window counters in a public ETS table
lib/pesque/did_resolver.ex      did:web and did:plc document resolution
lib/pesque/handle_resolver.ex   DNS TXT and well-known handle resolution
lib/pesque/service_auth.ex      ES256K service-auth tokens, mint and verify
lib/pesque/plc.ex               did:plc minting, handle updates, operations
lib/pesque/plc/directory.ex     the PLC directory over HTTPS
lib/pesque/plc/keys.ex          repo and rotation key files
lib/pesque/crawl.ex             announce the server to a relay at boot
lib/pesque/oauth.ex             the authorization server: PAR, codes, tokens, revocation
lib/pesque/oauth/keys.ex        the P-256 OAuth key, loaded once at boot
lib/pesque/oauth/nonce.ex       the server-issued DPoP nonce
lib/pesque/oauth/request.ex     the pushed request and the code it authorizes
lib/pesque/oauth/token.ex       one issued access or refresh token
lib/pesque/oauth/client.ex      client_id resolution and metadata validation
lib/pesque/oauth/fetch.ex       the outbound HTTPS request, SSRF-hardened
lib/pesque/oauth/client_assertion.ex  private_key_jwt verification
```

`Pesque.RepoStore` is the only module allowed to write SQL, and the only place
that knows the storage layout, so a query in a controller would have to be
audited against a schema it can change.

**HTTP edge.**

```
lib/pesque_web/endpoint.ex      plugs, parsers, static legal pages
lib/pesque_web/router.ex        every route, and where the rate limits live
lib/pesque_web/xrpc.ex          the error shape
lib/pesque_web/xrpc/errors.ex   domain reason to status and message
lib/pesque_web/xrpc/*_controller.ex
lib/pesque_web/firehose.ex      the websocket
lib/pesque_web/plugs/*.ex       auth, admin, CORS, rate limit, security headers
lib/pesque_web/oauth/*.ex       PAR, the authorize page, token, revocation, metadata
lib/pesque_web/oauth/errors.ex  domain reason to OAuth error code
lib/pesque_web/oauth/proof.ex   reads and checks the DPoP proof on a request
```

Controllers parse, delegate, and map. `Pesque.Accounts.authorize_write/2` and
`PesqueWeb.Xrpc.Errors` are the two places where policy that is not protocol is
decided.

### Supervision tree

```
Pesque.Supervisor (one_for_one)
├── Pesque.Repo                  SQLite, WAL, busy timeout 5s
├── Pesque.RateLimit             owns one public ETS table
├── Registry (duplicate)         Pesque.EventRegistry, firehose listeners
├── Registry (unique)            Pesque.RepoRegistry, one pid per DID
├── Pesque.RepoSupervisor        DynamicSupervisor for RepoServer
├── Pesque.EventReaper           daily sweeps
└── PesqueWeb.Endpoint           Bandit
```

Before the tree starts, `Pesque.Application.start/2` runs, in order:
`Storage.init!/0`, `Secret.load!/0`, `Identity.load!/0`, `OAuth.Keys.load!/0`,
`Lexicon.Registry.reload/0`, `Release.migrate/0`. Then a boot log line and, if
`PDS_CRAWLER` is set, a task that asks each relay to crawl this server.

### One process per repository

`Pesque.RepoServer` is a GenServer holding, for one DID: the entry map
(`%{"collection/rkey" => %CID{}}`), `rev`, `tid_int`, and the account's signing
key. `Pesque.RepoSupervisor.ensure_started/1` starts one on demand, so an
account with no writes costs one `users` row.

- **Writes are serialized per repo.** That is the consistency model a PDS needs,
  and it comes free from one process owning the state.
- **The signing key lives in the process that owns the repo**, so the process
  that mutates the tree signs the commits.
- **`init/1` rehydrates from the database and generates a genesis commit** if the
  repo has no `rev` yet, so every repo has a signed head before its first record.

### Storage layout

```
data/
├── pesque.db
│   ├── users              did, handle, username, pubkey_multibase, email, password_hash, plc_operation
│   ├── records            did, collection, rkey, cid, data        (latest version per key)
│   ├── blocks             did, cid, data                          (every version ever written)
│   ├── events             did, seq, payload                       (firehose frames, pre-encoded)
│   ├── meta               key, value                              (root:, rev:, commit:, tid_int: per DID)
│   ├── refresh_tokens     hashed token, jti, did, expires_at
│   ├── account_deletion_tokens  hashed token, did, expires_at
│   ├── invite_codes       code, use_count, uses, used_by
│   ├── oauth_requests     hashed request_uri, code, client, DPoP jkt
│   └── oauth_tokens       hashed token, jti, kind, session_id
├── server.secret
├── keys/<sha256(did)>.key
├── keys/<sha256(did)>.rotation.key
├── keys/oauth.p256.key
├── blobs/<sha256(did)>/<cid>
└── lexicons/
```

`records` holds only the latest version of each key, which is what `listRecords`
and `getRecord` read, while `blocks` holds everything, which is what makes
`getRecord?cid=` for a superseded version possible. Event rows store their
payload already CBOR-encoded, so a crash cannot leave an empty-payload row.

### Deliberate choices

| Choice | Why | Cost |
| --- | --- | --- |
| Protocol code written here | A reference implementation should show the protocol | Every spec detail is yours to track |
| SQLite | One file, no server, transactional | Single writer. Fine for one PDS, wrong for a big one |
| `did:web` by default | No dependency on the PLC directory | The identity dies with the domain. `did:plc` is opt-in |
| One blob directory | Backup is one `tar` | No CDN, no replication, no dedup across accounts |
| Both session kinds | OAuth clients and legacy clients both work | Two token formats and two keys to keep apart |
| Outbound HTTPS to PLC, handle resolution, OAuth metadata and crawlers | Each is a profile requirement | Each is where a stranger picks a URL this server fetches. See `Pesque.OAuth.Fetch` |
| Incremental MST update, rebuild as fallback | Canonical output stays a pure function of the entry set | A tree that cannot be walked costs a full rebuild |
| Two error mappers, `Xrpc.Errors` and `OAuth.Errors` | The wire formats differ | Adding a reason means adding a clause, on purpose |

## The write path

`createRecord` from the HTTP body to a frame on every connected firehose socket.
Nine steps, each in one module.

**1. Authenticate.** `PesqueWeb.Plugs.Auth.call/2` decides the token by its
`alg`: an OAuth access token is ES256, checked against the JWKS and bound to a
DPoP proof over this request; a legacy session token is HS256. Both put the DID
and the user struct on the conn. The account is looked up, not inferred from the
subject: a token naming an account this server does not host is rejected.

**2. Authorize the repo.** `RepoController.with_owned_repo/2` calls
`Pesque.Accounts.authorize_write/2`, which resolves the requested repo to a
canonical DID and compares it with the authenticated one. An unknown repo and
another account's repo answer identically, so the write path cannot enumerate
hosted DIDs. A deactivated account owns nothing writable.

**3. Find the repo process.** `Pesque.RepoSupervisor.ensure_started/1` returns
the registered pid or starts one.

**4. Validate the shape.** `Pesque.RepoServer.handle_call/3` checks the
collection against the NSID rules and the rkey against
`[a-zA-Z0-9._~:-]{1,512}` (rejecting `.` and `..`). A missing rkey gets a fresh
TID from the counter that drives revs.

**5. Validate the record.** `Pesque.Record.check/3` verifies that `$type` is the
collection being written to and that the fields match the lexicon schema.
Failures come back as a path per mistake.

**6. Convert and encode.** `Pesque.Commit.encode_write/4` runs
`Pesque.Lexicon.from_json/1`, turning `{"$link": cid}` into a `%CID{}` and
`{"$bytes": b64}` into a `%CBOR.Bytes{}`, then DAG-CBOR encodes it and takes the
CID. This is the last point a bad value can be turned away.

**7. Commit.** `Pesque.Commit.commit/2` is the whole protocol, pure: apply the
changes to the entries, update the MST against the stored root (falling back to
a rebuild), mint `rev` and `tid`, sign the commit with the account key, and
return the new state plus every block it creates.

**8. Persist, atomically.** `Pesque.RepoServer.commit/2` opens one
`Repo.transaction` and claims the event seq first, inserts only the genuinely new
blocks, writes the record row, updates `meta`, and inserts the pre-encoded event.
Two writers racing on the same seq lose on the primary key and roll back whole.

**9. Fan out.** After the transaction returns,
`Registry.dispatch(Pesque.EventRegistry, :firehose, ...)` sends the frame to every
connected socket. Outside the transaction on purpose: a subscriber that crashes
must not roll back a commit that is already durable.

### The firehose

`PesqueWeb.Firehose` is server-push only. On connect it replays from the cursor,
then forwards live frames. No cursor means live only. A cursor ahead of
`max_seq()` gets `FutureCursor` and the socket closes. A cursor older than the
oldest retained event, or more than 10,000 frames behind, gets `#info`
`OutdatedCursor` then the replay. An unparsable cursor is `InvalidCursor`, not
"treat it as no cursor".

`#commit` carries `prevData` (the previous MST root) and a per-op `prev` for
updates and deletes, so an inductive consumer can apply the diff. A commit whose
CAR is over 2 MB or whose op count is over 200 goes out as `#commit` with
`tooBig: true` followed by a `#sync` carrying the commit alone, telling the
consumer to re-fetch the repo. `#identity` and `#account` are the other frames.

### Account creation

`Pesque.Accounts.create_account/4`: derive the DID and handle with
`identity_for/1` (through `Pesque.Plc` under `PDS_IDENTITY=plc`); check the
password, email, and availability before anything is written; `claim_key/1`
creates the signing key file with `O_EXCL`, so two concurrent calls produce one
account and one `:eexist`; one transaction consumes the invite code and inserts
the user row; any failure removes the key files. Then
`Pesque.Events.emit_account/2` writes an `#account` frame and pushes it.

## The primitives

Each module below has one invariant that is easy to get wrong.

- **DAG-CBOR** (`Pesque.CBOR`): map keys sorted length-first then bytewise, floats
  always 64-bit, byte strings explicit, links tag 42. Determinism is the invariant:
  the same record encoded twice must produce the same bytes and CID. Invalid UTF-8
  raises rather than encoding, which is why `Lexicon.from_json/1` rejects it first.
- **CID** (`Pesque.CID`): CIDv1 only, sha2-256, `dag-cbor` (0x71) for blocks and
  `raw` (0x55) for blobs. `parse/1` raises and is for a CID this server computed;
  `safe_parse/1` answers `:error` and is what every request path uses.
  `Blob.parse_cid/1` matches on the decoded struct, so nothing a request supplies
  reaches a path without passing that match.
- **Merkle Search Tree** (`Pesque.Mst`): a pure function of the entry set. Key
  depth is the leading zero bits of `sha256(key)` in 2-bit chunks; a node at layer
  L holds the keys of depth exactly L in its range, prefix-compressed, with
  subtrees hanging between entries. Output is byte-identical to the reference
  TypeScript implementation. `update_tree/3` reads only the nodes a change
  rewrites; a tree that cannot be walked falls back to `build/1`.
- **CAR** (`Pesque.Car`): CAR v1, header `{"version": 1, "roots": [...]}`, then
  each block as `varint(cid ++ length) <> cid <> bytes`. Blocks are sorted by CID
  bytes, which makes the output independent of map iteration order. `stream/2`
  emits the same bytes without holding the repo in memory.
- **Commit frames** (`Pesque.Commit.frames/4`): the header is its own CBOR item and
  the body the next, so a consumer reads one item to learn the type and one for the
  payload. `blocks` carries only the blocks this transaction inserted, so a relayer
  never receives a block twice.
- **TID** (`Pesque.Tid.next/2`): 13 base32-sortable chars,
  `max(last + 1, now <<< 10 ||| clock_id)`, monotonic within a microsecond because
  the same counter issues revs and rkeys.
- **JWT** (`Pesque.Token`): HS256 legacy sessions. `verify/3` folds a bad
  signature, a wrong scope and an expired token into one `{:error, :invalid_token}`,
  because distinguishing them tells an attacker which half they got right.
- **Grapheme segmentation** (`Pesque.Grapheme`): UAX #29 extended grapheme
  clusters, for `maxGraphemes`. The generated tables are committed, so the server
  never fetches the UCD at runtime. Rebuild them when the pinned Unicode version
  moves with `mix pesque.gen_unicode` (or `mix pesque.gen_unicode path/to/ucd`).
- **Varint, base32, base58**: unsigned LEB128 (`decode/1` raises on a truncated or
  over-64-bit varint, which stops a crafted CID from being an unbounded shift); RFC
  4648 base32 lowercased and unpadded, `[a-z2-7]`, which is what makes a CID safe
  as a filename; base58btc, only for multibase public keys.

## Where to change things

- **XRPC method.** Route it in `lib/pesque_web/router.ex` in the pipeline matching
  its auth requirement (`:session_limits`, `:auth_read`, `:auth_write`,
  `:auth_account`, `:read_limits`, `:write_limits`, `:admin`); the catch-all
  answers `501`. Handle it in the controller, put the logic in a domain module
  returning `{:ok, value}` or `{:error, reason}`, and map the reason in
  `lib/pesque_web/xrpc/errors.ex`. A reason without a clause is a compile-and-test
  failure, which is the point.
- **OAuth scope.** Add it to `@supported` in `lib/pesque/oauth/scopes.ex`; it then
  appears in `scopes_supported` in both metadata documents. Enforce it where it is
  spent: `Pesque.OAuth.verify_access_token/1` returns the granted scope. A scope
  granted but not enforced is worse than one refused.
- **Token scheme.** `Pesque.Token` signs legacy sessions and
  `PesqueWeb.Plugs.Auth` verifies them. OAuth is a parallel path: its own signer,
  storage (`oauth_tokens`), error mapper and endpoints under `/oauth`.
  `Plugs.Auth` decides by `alg` and runs the DPoP and scope checks for the OAuth
  arm.
- **Storage backend.** `Pesque.RepoStore` is the entire SQL surface, and
  `Pesque.Blob` plus `Pesque.Storage` the entire file surface. A Postgres backend
  means a second `RepoStore` and a `RepoSupervisor` that starts repos against it;
  the pure layer does not change.
- **Lexicons.** `mix pesque.sync_lexicons` is the only thing that writes to
  `priv/lexicons`, and it is idempotent: files already on disk with the same NSID
  are replaced, files upstream no longer publishes are left alone.
