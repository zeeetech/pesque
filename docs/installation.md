# Installation

How to run a Pesque server, and how to check that it works.

Two deployment paths are supported, and both run the same pinned OCI image:
the Compose bundle on any Docker host, and the NixOS module. Running from
source is for development.

## Requirements

- A running Docker daemon. Both supported paths run the
  `ghcr.io/zeeetech/pesque` image; the Compose bundle also needs Docker
  Compose v2.
- Anything beyond `localhost` needs a real hostname and TLS: `did:web`
  resolution is an HTTPS fetch on your domain, so a server reachable only
  over plain HTTP has an identity nothing can resolve. Pesque ships no TLS
  proxy; the server speaks plain HTTP and the proxy in front of it is the
  operator's job ([Behind a TLS proxy](#behind-a-tls-proxy)).
- Development from source needs Elixir 1.19+ on OTP 28+ and a C toolchain
  (the SQLite driver compiles from source). The deployment paths need no
  toolchain at all.

## Choose your shape

The server's own DID is always `did:web:<hostname>`, derived from the
hostname and served at `/.well-known/did.json`. The `mode` setting decides
only the account topology:

| | `single` (default) | `multi` |
| --- | --- | --- |
| Accounts | exactly one | many |
| Account handle | bare handle domain | `alice.example.com` |
| Default account DID | server's `did:web` | minted `did:plc` |
| Browser signup page | no | yes |
| Moving an account in ([Operations](operations.md#moving-an-account-in)) | no | required |

One account, your own domain, no directory dependency: `single`. Hosting
anyone else, taking browser signups, or planning to migrate an account in
from another PDS: `multi`.

`pesque account create --identity web|plc` picks the DID method per account.
The default is `web` in `single` mode and `plc` in `multi`; `--identity web`
is rejected under `multi`, because multi-user `did:web` would need a
subdomain DID, document, DNS record and certificate per account. The
trade-off: `did:web` ties the identity to a domain you control and needs no
directory; `did:plc` survives a hostname move and is what the official app
and account migration expect, at the cost of depending on the PLC directory
and a rotation key that lives in the data directory and must be backed up
with it.

## Docker: the Compose bundle

Every release publishes `pesque-compose-<version>.tar.gz` next to
`SHA256SUMS`. Download both from the
[latest release](https://github.com/zeeetech/pesque/releases/latest), verify
and unpack:

```bash
sha256sum -c SHA256SUMS
tar -xzf pesque-compose-<version>.tar.gz
cd pesque
```

The bundle is three files: `compose.yaml` (the service definition, pinned to
that release's image), `pesque` (the host-side command, a short POSIX shell
script you can read before you run it) and `pesque.conf.example`. First run:

```bash
./pesque init                        # writes pesque.conf, creates backups/
$EDITOR pesque.conf                  # hostname, handle domain, mode
docker compose up --detach --wait
./pesque account create --handle alice.example.com --email alice@example.com
```

`init` copies the example without overwriting, so unpacking a newer bundle
over the same directory is the update path: your `pesque.conf`, `backups/`
and data volume all survive, and `docker compose up --detach --wait` pulls
the new pinned image. Updates are manual; nothing updates the server for
you.

Lifecycle is Docker Compose itself, run from the bundle directory:

```bash
docker compose up --detach --wait    # create and start
docker compose stop pesque           # stop, data kept
docker compose restart pesque        # picks up an edited pesque.conf
docker compose logs -f pesque        # follow the logs
```

The server state lives in the named volume `pesque-data` (`/data` in the
container), and `./pesque.conf` is bound read-only at `/data/pesque.conf`.
The port publishes as `127.0.0.1:4000:4000`: loopback because a TLS proxy on
the same host is expected. If you edit the published side, the container
port must match `port` in the conf.

The `./pesque` command is everything that touches the data directly; it runs
each verb in a throwaway container from the same image, against the same
volume:

```bash
./pesque doctor                      # federation preflight
./pesque status
./pesque account create --handle alice.example.com --email alice@example.com
./pesque account list
./pesque invite create
./pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
./pesque config validate             # reads the conf the way boot will, boots nothing
./pesque backup                      # writes into ./backups
./pesque restore ARCHIVE_NAME        # cold; see Operations
```

Every verb takes `--help`. `account create` and `migrate` prompt for the
password with echo off, or read it from stdin (`echo secret | ./pesque ...`),
so it never lands in your shell history or the environment. The image runs
as a non-root user and carries a `HEALTHCHECK`, which is what
`up --detach --wait` waits on.

## NixOS

The flake's module runs the same pinned image under systemd, generates the
configuration, and puts a configured `pesque` command on PATH:

```nix
{
  imports = [ pesque.nixosModules.default ];

  services.pesque = {
    enable = true;
    image = "ghcr.io/zeeetech/pesque:1.14.2";  # explicit tag or digest; latest is refused
    hostname = "pds.example.com";
    mode = "multi";
    handleDomain = "example.com";
    crawler = [ "https://bsky.network" ];
    uid = 33333;                               # no defaults; the container runs as these
    gid = 33333;
  };
}
```

The module options are the whole configuration: they are written to a
`pesque.conf` in the store and mounted read-only, and
`services.pesque.settings` takes any extra conf key verbatim.
`services.pesque.dataDir` (default `/var/lib/pesque`) holds the entire
server; `backupDir` (default `dataDir/backups`) holds the archives. `uid`
and `gid` have no defaults: set them to the current data owner when adopting
an existing installation, because the module never changes ownership of
existing state. `services.pesque.requiredMounts` names paths that must
already be mountpoints, for datasets that could otherwise be hidden by an
empty directory (a ZFS dataset is the case it exists for); the service and
every one-off command check them before touching data, and nothing is
mounted or chowned automatically.

Docker is required; `virtualisation.docker.enable` is defaulted on.
Lifecycle belongs to systemd:

```bash
sudo systemctl start pesque
sudo systemctl stop pesque
journalctl -u pesque -f
```

The `pesque` command on PATH forwards the data work to one-off containers
against the same mounts. It needs Docker access, so on most hosts that means
`sudo`:

```bash
sudo pesque doctor
sudo pesque account create --handle alice.example.com --email alice@example.com
sudo pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
sudo pesque health                   # inspects the running container, starts nothing
sudo pesque backup                   # writes into backupDir
sudo systemctl start pesque-backup   # the same backup as a oneshot, for timers
```

Updates are manual: raise `image` to a new pinned tag and
`nixos-rebuild switch`. Exactly as in Docker, the server speaks plain HTTP
and expects a TLS proxy; `listenAddress` defaults to `127.0.0.1`, so the port
is reachable only by the proxy on the same host or a tunnel.

## From source

For development, not a supported deployment:

```bash
mix deps.get
mix phx.server
```

Migrations run on boot and the data directory is created if missing. There
is no `mix ecto.create`, no seed step and no secret to invent: Pesque
generates `data/server.secret` on first boot. The one setting to decide
before starting is `PDS_HOSTNAME`; with no proxy in front, say so:

```bash
PDS_HOSTNAME=localhost PDS_URL_SCHEME=http mix phx.server
```

There are no `mix pesque.*` tasks any more (`mix pesque.sync_lexicons`
aside). Operator verbs run through the CLI module directly:

```bash
mix run -e 'Pesque.Cli.main()' account create \
  --handle alice.example.com --email alice@example.com
```

This boots the whole application, endpoint included, so the server's log
lines appear around the verb's output; the verb exits the VM when it is
done.

The browser signup and migration pages are `multi` flows, and both mint real
`did:plc` identities at the public PLC directory. To develop without that,
add `PDS_PLC_LOCAL=true`: the operations are kept under `data_dir` instead.
The setting is refused outside the dev and test environments.

## Behind a TLS proxy

Required for federation, and required for the rate limits to mean anything
([Operations](operations.md#rate-limits-and-the-proxy)). Pesque ships no
proxy and no certificates: everything in this section is something the
operator runs in front of the server.

The name coverage is the interesting part under `mode = multi`, where
handles look like `alice.<hostname>`: the proxy has to answer for names that
do not exist at deploy time. Caddy with on-demand TLS mints a per-name
certificate the first time a client handshakes for that name, after asking
the server whether the name is one it owns:
`GET /xrpc/_tls-check?domain=<name>` answers 200 for the server's own
hostname and for handles the accounts table carries, and 403 for anything
else, which is Caddy's signal not to issue. Every certificate comes through
the ordinary HTTP-01 challenge, so there is no wildcard certificate to buy
and no DNS-01 provider to wire up: point `<hostname>` (or `*.<hostname>`) at
the server, and certificates appear as clients reach the names. The ask
endpoint is public on purpose and hides nothing (`resolveHandle` answers the
same question), and it runs under the read budget.

A Caddy proxying a server on the same host, on-demand TLS over a loopback
ask endpoint:

```caddyfile
{
	on_demand_tls {
		ask http://127.0.0.1:4000/xrpc/_tls-check
	}
}

pds.example.com, *.pds.example.com {
	encode zstd gzip
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:4000
}
```

A handle domain you set apart from the hostname needs its own on-demand site
label beside the wildcard: the ask endpoint allows the name, but Caddy only
matches the labels it is given.

nginx needs the same proxy, plus `proxy_http_version 1.1`, the `Upgrade` and
`Connection` headers, `proxy_read_timeout 3600s` and `proxy_buffering off`,
because the firehose stays open indefinitely. `Connection` needs a
`map $http_upgrade $connection_upgrade { default upgrade; '' close; }` at
the `http` level. nginx has no on-demand issuance of its own, so for `multi`
handles point a wildcard DNS record at it and terminate TLS for the wildcard
name with a certificate covering `*.<hostname>`.

## Configuration

Every knob can be set as an environment variable or in a `pesque.conf` file.
The environment wins, then the file, then the default; an invalid value fails
at boot instead of falling back silently. `config/runtime.exs` is the
reference for names, defaults and validation.

The file is plain `key = value`, one per line, `#` for comments. The key is
the variable without the `PDS_` prefix, lowercased: `hostname =
pds.example.com` is `PDS_HOSTNAME`. A key the server does not know is an
error, so a typo fails boot instead of being ignored.

Who reads what: the Compose bundle binds your `pesque.conf` into the
container; the NixOS module generates the file from its options; a bare
container or a source checkout reads `PDS_CONFIG`, or `pesque.conf` in the
working directory, or the environment. Inside the container the path is
`/data/pesque.conf`.

| Variable | Key in the file | Default | Purpose |
| --- | --- | --- | --- |
| `PDS_DATA_DIR` | `data_dir` | `data` | Directory holding the entire server state |
| `PDS_HOSTNAME` | `hostname` | `localhost` | Public hostname. Drives the DID, the DID document and every advertised URL |
| `PDS_MODE` | `mode` | `single` | `single` or `multi`. See [Choose your shape](#choose-your-shape) |
| `PDS_HANDLE_DOMAIN` | `handle_domain` | hostname | The domain accounts get handles under |
| `PDS_HANDLE` | `handle` | hostname | The handle the server publishes under `single` |
| `PDS_PORT` | `port` | `4000` | Port the process binds |
| `PDS_URL_SCHEME` | `url_scheme` | `https` | What the server tells the world to fetch |
| `PDS_URL_PORT` | `url_port` | `443` (`port` for http) | The advertised port |
| `PDS_REGISTRATION` | `registration` | `closed` | `open`, or invite codes |
| `PDS_PLC_DIRECTORY` | `plc_directory` | `https://plc.directory` | PLC directory used when an account is minted as `did:plc` |
| `PDS_LEXICON_AGGREGATOR` | `lexicon_aggregator` | empty | https base URL permission sets are fetched from when a client asks for one with `include:` and it is not vendored. Unset resolves only the vendored sets |
| `PDS_CRAWLER` | `crawler` | empty | Comma-separated relay base URLs to announce the server to at boot |
| `PDS_BLOB_UPLOAD_LIMIT` | `blob_upload_limit` | `5242880` (5 MiB) | Largest blob `uploadBlob` accepts, reported in `describeServer.blobUploadLimit` |
| `PDS_REPO_IMPORT_LIMIT` | `repo_import_limit` | `104857600` (100 MiB) | Largest `importRepo` body |
| `PDS_PROXY_TIMEOUT` | `proxy_timeout` | `15000` | How long a proxied call may take before it is answered 504, in milliseconds |
| `PDS_PROXY_RESPONSE_LIMIT` | `proxy_response_limit` | `10485760` (10 MiB) | Largest body a proxied call may return |
| `PDS_ADMIN_DIDS` | `admin_dids` | empty | Extra DIDs allowed to call `createInviteCodes` under `multi` |
| `PDS_PRIVACY_POLICY_URL` | `privacy_policy_url` | empty | Your privacy policy, published by `describeServer`. Unset omits the link |
| `PDS_TERMS_OF_SERVICE_URL` | `terms_of_service_url` | empty | Your terms of service, published by `describeServer`. Unset omits the link |

`port` is where the process binds; `url_scheme` and `url_port` are what it
advertises. Behind a proxy, listening on 4000 and advertising 443 is correct.
`hostname` and `handle_domain` are often the same and rarely should be: a
server at `pds.example.com` can hand out `alice.example.com` handles.

Do not change `hostname` on a server with accounts: a `did:web` account is
bound to it, and a `did:plc` account keeps its DID but its published PDS
endpoint must still match the server configuration. Changing `handle_domain`
does not rewrite stored handles, so existing handles stop resolving.

`pesque config validate` boots nothing: it reads the environment and the
conf the way the server will at boot, then prints every resolved setting
with the layer that decided it (environment, `pesque.conf:LINE`, or
`(default)`). Run it after any configuration change or release swap: an
unknown `PDS_*` variable or conf key fails boot, and this names it without a
failed boot.

## Create an account

Registration is closed by default, so the first account is created by the
operator, which skips the invite requirement:

```bash
./pesque account create \
  --handle alice.example.com \
  --email alice@example.com
```

(`sudo pesque account create ...` on NixOS; `mix run -e 'Pesque.Cli.main()'
account create ...` from source.) The password is read from a no-echo
prompt, or from stdin so it can be piped; it never takes a flag or an
environment variable. Later accounts need an invite code, minted by the
operator (`./pesque invite create`, or `com.atproto.server.createInviteCodes`
with your DID named in `admin_dids`) and spent once, in the same transaction
that inserts the account. `registration = open` drops the requirement.

## Verify

Run these in order. Each one narrows down where a later failure is.

```bash
# 1. process up, database migrated. 200 = ok, 503 = migrations did not run
curl -s http://localhost:4000/xrpc/_health

# 2. the server's own identity. did must match hostname
curl -s http://localhost:4000/xrpc/com.atproto.server.describeServer

# 3. a session, then a write. Writes need the token, reads do not
curl -s -X POST https://pds.example.com/xrpc/com.atproto.server.createSession \
  -H "content-type: application/json" \
  -d '{"identifier":"alice.example.com","password":"secret123"}'

curl -s -X POST https://pds.example.com/xrpc/com.atproto.repo.createRecord \
  -H "authorization: Bearer $ACCESS_JWT" -H "content-type: application/json" \
  -d '{"repo":"did:web:example.com","collection":"app.bsky.feed.post","record":{"$type":"app.bsky.feed.post","text":"hello from pesque","createdAt":"2026-01-01T00:00:00Z"}}'

# 4. the firehose. Write another record and a #commit frame appears
websocat "wss://pds.example.com/xrpc/com.atproto.sync.subscribeRepos?cursor=0"

# 5. identity resolves from outside
curl -s https://pds.example.com/.well-known/did.json
curl -s "https://pds.example.com/xrpc/com.atproto.identity.resolveHandle?handle=alice.example.com"
```

If `did` says `localhost`, `hostname` was not set for this process. The
`links` the server advertises ship as placeholders, so set
`privacy_policy_url` and `terms_of_service_url` before pointing a real
domain at the server
([Operations](operations.md#replace-the-legal-pages)). A firehose that
connects and stays silent while writes succeed is proxy buffering; identity
that works from your machine but not elsewhere is a proxy or firewall.

## Where federation breaks

- `did:web` requires a public HTTPS document at the hostname. A server
  reachable only over plain HTTP does not federate.
- A `did:plc` account's DID document is served by the directory, not by
  Pesque.
- `multi` accounts are `did:plc`; did:web subdomain accounts are not
  supported.
