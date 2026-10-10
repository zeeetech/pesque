# Migration

Moving an existing ATProto account onto a Pesque server. The DID does not
change, so the handle's DNS record does not change either and keeps resolving
throughout the move.

Two servers are involved: the old PDS, which still holds the account, and the
new Pesque server. Steps 2, 3, 4 and 6 read from the old PDS and write to the
new one.

## One command

`mix pesque.migrate` runs the whole move on the new server, stopping only at the
identity step, which the old PDS has to sign:

```bash
PASSWORD='...' mix pesque.migrate \
  --old-pds https://bsky.social \
  --handle zoedsoupe.zeetech.io \
  --email zoedsoupe@example.com \
  --password-env PASSWORD
```

In the container the mix task does not exist, so the wrapper runs the release
equivalent (with stdin attached for the code prompt):

```bash
PASSWORD='...' scripts/pesque migrate \
  --old-pds https://bsky.social \
  --handle zoedsoupe.zeetech.io \
  --email zoedsoupe@example.com
```

The wrapper drives compose by default and a container you already run with
`PESQUE_BACKEND=docker`; both attach a terminal so the code prompt can be
answered. Both are in the [installation guide](installation.md).

It opens a session on the old PDS, creates the account here (deactivated),
imports the repo and every blob, fetches the recommended credentials, then asks
the old PDS for a PLC operation signature. On `bsky.social` that emails a code:
the task prompts for it, has the old PDS sign the operation, submits it here,
activates the new account and deactivates the old one. The password is the old
PDS account password, reused as the new account's password. Use the account
password, not an app password: the PLC endpoints the move relies on require a
full-access session, and an app password never carries one, so the old PDS
answers `400 Bad token scope`. If the account has 2FA, turn it off for the move;
the task cannot supply a second factor. A run that fails before the PLC
submission can be re-run: the account is reused rather than recreated.

### On NixOS

`services.pesque` runs the move as the `pesque-migrate` oneshot, which has no
terminal to prompt on. So the code step is split across two starts, both driven
by `/zdata/pesque/migrate.env`:

```sh
sudo systemctl start pesque-migrate   # asks the old PDS to email the code
# check the email, then add MIGRATE_PLC_TOKEN=<code> to migrate.env
sudo systemctl start pesque-migrate   # runs the move using that code
```

The first start does not import anything: it only requests the code. The second
one does the whole move (create, import, sign, submit, activate) and is what
prints `migration complete`. Setting `MIGRATE_PLC_TOKEN` ahead of a run skips
the request, so the same env file drives both.

The rest of this guide is the same move by hand, one step at a time, which is
what to fall back to when something in the task does not fit.

## Before you start

- The new server runs `PDS_MODE=path_multi` with `PDS_IDENTITY=plc`, behind TLS,
  with `PDS_CRAWLER` set if you want a relay to pick it up.
- The handle is verified before it is accepted: DNS TXT at `_atproto.<handle>`,
  then the well-known document, cross-checked against the DID document's
  `alsoKnownAs`. Publish the record first or the import is refused.
- The old PDS holds the rotation key during the move. The new PDS mints its own
  and returns it in the recommended credentials.
- `signPlcOperation` and `requestPlcOperationSignature` are not implemented on
  this server; the old PDS signs the operation in step 6.
- Migrating off `bsky.social` is one-way. Once the PLC operation lands, the old
  PDS no longer controls the identity.

## The move

**1. Deploy the new PDS.**

```bash
PDS_MODE=path_multi PDS_IDENTITY=plc PDS_HOSTNAME=pds.example.com \
PDS_HANDLE_DOMAIN=example.com PDS_CRAWLER=https://relay.example.com
```

**2. Prove control of the DID.** Get a service-auth token from the old PDS, with
`aud` the new PDS's DID and `lxm` `com.atproto.server.createAccount`:

```bash
curl -s "https://old.example.com/xrpc/com.atproto.server.getServiceAuth?aud=did:web:pds.example.com&lxm=com.atproto.server.createAccount"
```

Call `createAccount` on the new PDS with the existing `did` and that token. The
account is created deactivated:

```bash
curl -s -X POST https://pds.example.com/xrpc/com.atproto.server.createAccount \
  -H "authorization: Bearer $SERVICE_AUTH" -H "content-type: application/json" \
  -d '{"did":"did:plc:...","handle":"alice.example.com","email":"alice@example.com","password":"secret123"}'
```

**3. Import the repo.** `getRepo` from the old PDS, `importRepo` on the new one:

```bash
curl -s "https://old.example.com/xrpc/com.atproto.sync.getRepo?did=did:plc:..." -o repo.car
curl -s -X POST "https://pds.example.com/xrpc/com.atproto.repo.importRepo" \
  -H "authorization: Bearer $ACCESS_JWT" -H "content-type: application/vnd.ipld.car" \
  --data-binary @repo.car
```

`importRepo` signs a new commit over the imported tree with this server's key and
points its `prev` at the imported commit.

**4. Import blobs.** `sync.listBlobs` from the old PDS, `uploadBlob` each CID to
the new one, then `listMissingBlobs` to confirm:

```bash
curl -s "https://old.example.com/xrpc/com.atproto.sync.listBlobs?did=did:plc:..."
curl -s -X POST "https://pds.example.com/xrpc/com.atproto.repo.uploadBlob" \
  -H "authorization: Bearer $ACCESS_JWT" --data-binary @blob
curl -s "https://pds.example.com/xrpc/com.atproto.repo.listMissingBlobs" \
  -H "authorization: Bearer $ACCESS_JWT"
```

**5. Get the recommended credentials.** `getRecommendedDidCredentials` answers
the new signing key, the rotation key and this server's endpoint:

```bash
curl -s "https://pds.example.com/xrpc/com.atproto.identity.getRecommendedDidCredentials" \
  -H "authorization: Bearer $ACCESS_JWT"
```

**6. Move the identity.** Have the **old** PDS sign the PLC operation carrying
that document (`signPlcOperation`, because it holds the rotation key), then
`submitPlcOperation` on the new PDS:

```bash
curl -s -X POST "https://old.example.com/xrpc/com.atproto.identity.signPlcOperation" \
  -H "authorization: Bearer $ACCESS_JWT" -H "content-type: application/json" \
  -d @recommended.json

curl -s -X POST "https://pds.example.com/xrpc/com.atproto.identity.submitPlcOperation" \
  -H "authorization: Bearer $ACCESS_JWT" -H "content-type: application/json" \
  -d '{"operation": { ... }}'
```

This is the point of no return.

**7. Activate the new account, deactivate the old one.**

```bash
curl -s -X POST https://pds.example.com/xrpc/com.atproto.server.activateAccount \
  -H "authorization: Bearer $ACCESS_JWT"
curl -s -X POST https://old.example.com/xrpc/com.atproto.server.deactivateAccount \
  -H "authorization: Bearer $ACCESS_JWT"
```

## Caveats

- The DID does not change, so the handle's DNS record does not change and keeps
  resolving throughout.
- The handle is verified by DNS TXT or the well-known document before it is
  accepted, and the record must already be published or the import is refused.
- The new PDS's `submitPlcOperation` refuses an operation whose PDS endpoint is
  not this server, whose signing key is not the account's, or whose
  `alsoKnownAs` does not claim the account's handle.
- `getRecommendedDidCredentials` mints the rotation key on the first ask.
- A wildcard DNS record and a certificate for `*.<handle-domain>` are needed
  only for handles this server itself hosts. A TXT record avoids that.
