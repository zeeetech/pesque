# Installation

How to run a Pesque server, and how to check that it works.

## Requirements

Elixir 1.19+ on OTP 28+, and a C toolchain, for the SQLite driver. The
one-line install needs `curl` and a running Docker daemon (the docker
backend), or root on a Linux systemd host (the systemd backend). Anything
beyond `localhost` also needs a real hostname and TLS: `did:web` resolution
is an HTTPS fetch on your domain, so a server reachable only over plain HTTP
has an identity nothing can resolve. Pesque ships no TLS proxy; the server
speaks plain HTTP and the proxy in front of it is the operator's job
(below). See [Identity](identity.md).

## Run it locally

```bash
mix deps.get
mix phx.server
```

Migrations run on boot and the data directory is created if missing. There is no
`mix ecto.create`, no seed step and no secret to invent: Pesque generates
`data/server.secret` on first boot. The one setting to decide before starting is
`PDS_HOSTNAME`. By default the server advertises `https://$PDS_HOSTNAME`; with no
proxy in front, say so:

```bash
PDS_HOSTNAME=localhost PDS_URL_SCHEME=http mix phx.server
```

## Docker

A prebuilt image is published to GHCR, so a deploy needs no toolchain. The
host-side `pesque` CLI is a static binary shipped with each release,
checksum-verified against the release's `SHA256SUMS`; the bootstrap installer
puts it on PATH:

```bash
curl -fsSL https://github.com/zeeetech/pesque/releases/latest/download/install.sh | sh
```

First run is three commands: write a `pesque.conf`, create and start the
container, create the first account.

```bash
pesque config template --out pesque.conf   # fill in hostname, handle domain
pesque up
pesque account create --handle alice.example.com --email alice@example.com
```

`up` creates the container if it does not exist and starts it otherwise, so
after the first one the CLI owns that container's lifecycle: `down` stops it
and keeps the data, `restart` restarts it, and `update [tag]` pulls the image,
removes the container and recreates it on the new image. `update` is manual
only; nothing updates the server for you. `logs -f --tail N` follows the
server logs and `health` reports on the running one.

What the container runs and mounts is environment, not flags:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PESQUE_BACKEND` | detected | `docker` or `systemd`. The CLI probes for the container, then for the unit; `PESQUE_BACKEND` or `--backend` pins one |
| `PESQUE_CONTAINER` | `pesque` | The container the CLI creates and owns |
| `PESQUE_IMAGE` | `ghcr.io/zeeetech/pesque:latest` | Image `up` and `update` run. Build your own with `docker build -t pesque .` and point this at it |
| `PESQUE_DATA` | the named volume `pesque-data` | Host path mounted at `/data` |
| `PESQUE_CONFIG` | unset | Host path to a `pesque.conf`, mounted read-only at `/data/pesque.conf` |
| `PESQUE_PUBLISH` | `127.0.0.1:4000:4000` | Published port. Loopback by default because a proxy is expected; `100.64.0.1:4000:4000` serves a tailnet |

`PDS_HOSTNAME` is where your DID and every advertised URL come from and
`PDS_HANDLE_DOMAIN` decides what handles your accounts get; both live in the
conf. The container speaks plain HTTP and expects the proxy in front.

The one-off tasks (`doctor`, `account`, `migrate`) run in a throwaway
container from the same image, given the same data volume (and config) the
server was created with, so the task reads the same state the live server
does. That works before the first `up` too, which is how `config template`
writes a `pesque.conf` for a server that is not running yet. Without the CLI
the same task is one command; `-i` keeps stdin attached for the migration's
code prompt:

```bash
docker run --rm -i -v pesque-data:/data \
  -v "$PWD/pesque.conf:/data/pesque.conf:ro" \
  -e PDS_SERVE=false ghcr.io/zeeetech/pesque:latest \
  /app/bin/pesque doctor
```

`account create` and `migrate` prompt for the password with echo off, or read
it from stdin (`echo secret | pesque ...`), so it never lands in your shell
history or the environment. The move itself is the
[Migration guide](migration.md). The image carries a release, not Mix, so the
mix task in this guide does not run inside the container; `pesque` runs the
release equivalents.

## Release

```bash
MIX_ENV=prod mix release
_build/prod/rel/pesque/bin/pesque start
```

`bin/pesque stop` is a clean `SIGTERM`: the endpoint drains and the in-flight
commit finishes. Copy the release directory wherever you want it and run
`bin/pesque` from there. Under systemd, set `PDS_DATA_DIR`, `PDS_HOSTNAME` and
`PDS_HANDLE_DOMAIN`, then `ExecStart=/opt/pesque/bin/pesque start` and
`ExecStop=/opt/pesque/bin/pesque stop`.

## NixOS

The flake builds the release from source and runs it as a plain systemd service,
no container runtime:

```nix
services.pesque = {
  enable = true;
  hostname = "pds.example.com";
  mode = "multi";
  handleDomain = "example.com";
  crawler = [ "https://bsky.network" ];
};
```

`nix build .#pesque` builds the same release on its own; `services.pesque.package`
overrides what the service runs. The options are written to a `pesque.conf` in
the store and pointed at with `PDS_CONFIG`, so they are the whole configuration;
`services.pesque.settings` takes any extra `pesque.conf` key verbatim.
`services.pesque.dataDir` (default `/var/lib/pesque`) is the whole server, the
same one file and one directory as everywhere else.

The operator tasks are oneshot units that run the release verbs against the
same data directory:

```bash
systemctl start pesque-doctor
systemctl start pesque-account   # reads /var/lib/pesque/account.env
systemctl start pesque-migrate   # reads /var/lib/pesque/migrate.env
systemctl start pesque-backup    # writes pesque-backup-<stamp>.tar.gz into /var/lib/pesque
```

`services.pesque` also puts the host-side `pesque` CLI on PATH, built from
`cli/` with a pinned Zig. It reads the release and the config from the running
unit, and its one-offs run as the service user against the same data:
`sudo -u pesque pesque doctor`. That is also the form for the verbs the
oneshots do not cover (restore, account list/delete/reset-password/plc-token/
email-token/reset-token, invite, config). The lifecycle verbs no-op here,
since NixOS owns the unit.

Create the env files first, so the inputs never land in the Nix store. The
env file holds the non-secret inputs; the password file holds the password
alone, one line, and the unit feeds it on stdin (a oneshot has no terminal to
prompt on):

```bash
install -m600 /dev/null /var/lib/pesque/migrate.env
$EDITOR /var/lib/pesque/migrate.env   # MIGRATE_OLD_PDS, MIGRATE_HANDLE, MIGRATE_EMAIL
install -m600 /dev/null /var/lib/pesque/migrate.password
$EDITOR /var/lib/pesque/migrate.password   # the account password
```

The password is the account password, not an app password: the move needs
a full-access session, which an app password never carries.

The move stops at the PLC step for a code emailed to the account holder, and a
oneshot has no terminal to prompt on, so `pesque-migrate` is started twice: the
first start emails the code, then `MIGRATE_PLC_TOKEN` is added to the env file
and the second start completes the move. See
[Migration](migration.md#on-nixos).

`pesque-backup` is safe to start while the server is up: the database is
snapshotted first and the archive lands in `dataDir`. What the archive holds,
and how a restore swaps it in, is in
[Backup and restore](operations.md#backup-and-restore). A restore swaps the data
directory in place, so there is no unit for it: stop the server and run the
verb by hand as the `pesque` user, with the same `PDS_CONFIG` the service runs
(`systemctl cat pesque` shows both store paths):

```bash
systemctl stop pesque
sudo -u pesque env PDS_CONFIG=/nix/store/<...>-pesque.conf \
  /nix/store/<...>-pesque/bin/pesque restore /var/lib/pesque/pesque-backup-*.tar.gz
systemctl start pesque
```

The server speaks plain HTTP and expects a TLS proxy, exactly as in Docker.
`services.pesque.openFirewall` is off by default: the port should be reachable
only by the proxy on the same host or a tunnel.

## Behind a TLS proxy

Required for federation, and required for the rate limits to mean anything
(see [Operations](operations.md#rate-limits-and-the-proxy)). Pesque ships no
proxy and no certificates: everything in this section is something the
operator runs in front of the server.

The name coverage is the interesting part under `mode = multi`, where
handles look like `alice.<hostname>`: the proxy has to answer for names that
do not exist at deploy time. Caddy with on-demand TLS, the example below,
mints a per-name certificate the first time a client handshakes for that
name, after asking the server whether the name is one it owns.
`GET /xrpc/_tls-check?domain=<name>` answers 200 for the server's own hostname
and for handles the accounts table carries, and 403 for anything else, which
is Caddy's signal not to issue. Every certificate comes through the ordinary
HTTP-01 challenge, so there is no wildcard certificate to buy and no DNS-01
provider to wire up: point `<hostname>` (or `*.<hostname>`) at the server,
and certificates appear as clients reach the names.

The ask endpoint is public on purpose and adds no configuration: handle
existence is already public (resolveHandle answers the same question), so a
gate would hide nothing, and the route runs under the read budget. A handle
domain you set apart from the hostname needs its own on-demand site label
beside the wildcard, since the ask endpoint allows the name but Caddy only
matches the labels it is given.

A Caddy proxying a server on the same host, on-demand TLS over a loopback ask
endpoint:

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

nginx needs the same proxy, plus `proxy_http_version 1.1`, the `Upgrade` and
`Connection` headers, `proxy_read_timeout 3600s` and `proxy_buffering off`,
because the firehose stays open indefinitely. `Connection` needs a
`map $http_upgrade $connection_upgrade { default upgrade; '' close; }` at the
`http` level. nginx has no on-demand issuance of its own, so for
`multi` handles point a wildcard DNS record at it and terminate TLS for
the wildcard name with a certificate covering `*.<hostname>`.

## Configuration

Every knob can be set as an environment variable or in a `pesque.conf` file. The
environment wins, then the file, then the default; an invalid value fails at boot
instead of falling back silently. `config/runtime.exs` is the reference for names,
defaults and validation.

The file is plain `key = value`, one per line, `#` for comments. The key is the
variable without the `PDS_` prefix, lowercased: `hostname = pds.example.com` is
`PDS_HOSTNAME`. A key the server does not know is an error, so a typo fails boot
instead of being ignored. The starting point is `pesque config template --out
pesque.conf`, or `pesque.conf.example` in the repo.

The server reads `PDS_CONFIG`, or `pesque.conf` in the working directory. In
the container the path is `/data/pesque.conf`, inside the data directory:
`pesque up` binds `PESQUE_CONFIG` there read-only, so an edit to the mounted
file takes a `pesque restart`, and a container started without one runs on
the environment and the defaults.

| Variable | Key in the file | Default | Purpose |
| --- | --- | --- | --- |
| `PDS_DATA_DIR` | `data_dir` | `data` | Directory holding the entire server state |
| `PDS_HOSTNAME` | `hostname` | `localhost` | Public hostname. Drives the DID, the DID document and every advertised URL |
| `PDS_MODE` | `mode` | `single` | `single` or `multi`. See [Identity](identity.md) |
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
`hostname` and `handle_domain` are often the same and rarely should be: a server
at `pds.example.com` can hand out `alice.example.com` handles.

## Create an account

Registration is closed by default, so the first account comes from the mix task,
which skips the invite requirement:

```bash
mix pesque.account create \
  --handle alice.example.com \
  --email alice@example.com
```

The password is read from a no-echo prompt, or from stdin so it can be piped
(`echo secret123 | mix pesque.account create ...`); it never takes a flag or
an environment variable. Later accounts need an invite code,
minted through `com.atproto.server.createInviteCodes` and spent once, in the same
transaction that inserts the account. `PDS_REGISTRATION=open` drops the
requirement. On a `multi` server, minting codes also needs `PDS_ADMIN_DIDS`
(see [Operations](operations.md#security-notes)).

## Verify

Run these in order. Each one narrows down where a later failure is.

```bash
# 1. process up, database migrated. 200 = ok, 503 = migrations did not run
curl -s http://localhost:4000/xrpc/_health

# 2. the server's own identity. did must match PDS_HOSTNAME
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

If `did` says `localhost`, `PDS_HOSTNAME` was not set for this process. The
`links` it advertises ship as placeholders in `priv/static/`, so replace them
before pointing a real domain at the server
([Operations](operations.md#replace-the-legal-pages)). A firehose that connects
and stays silent while writes succeed is proxy buffering; identity that works
from your machine but not elsewhere is a proxy or firewall.
