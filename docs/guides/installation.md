# Installation

How to run a Pesque server, and how to check that it works.

## Requirements

Elixir 1.19+ on OTP 28+, and a C toolchain, for the SQLite driver. Docker or a
release needs a Docker daemon or a machine with `sh`, `nc` and a writable
directory. Anything beyond `localhost` also needs a real hostname and TLS:
`did:web` resolution is an HTTPS fetch on your domain, so a server reachable
only over plain HTTP has an identity nothing can resolve. See
[Identity](identity.md).

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

A prebuilt image is published to GHCR, so a deploy needs no toolchain:

```bash
docker pull ghcr.io/zeeetech/pesque:latest

docker run -d --name pesque -p 4000:4000 \
  -v pesque-data:/data \
  -e PDS_HOSTNAME=pds.example.com \
  -e PDS_MODE=path_multi \
  -e PDS_HANDLE_DOMAIN=example.com \
  -e PDS_CRAWLER=https://bsky.network \
  ghcr.io/zeeetech/pesque:latest
```

To build it yourself instead, `docker build -t pesque .` and use `pesque` as the
image name. `PDS_HOSTNAME` is where your DID and every advertised URL come from;
`PDS_HANDLE_DOMAIN` decides what handles your accounts get. The container speaks
plain HTTP and expects a proxy.

## The one-command install

For the common case, one droplet with TLS handled for you, there is a
`docker-compose.yml` and a `Caddyfile`, driven by `scripts/pesque`. Setup asks
two plain questions, starts the stack, waits until it is healthy, creates the
first account, and prints the DNS records to add:

```bash
scripts/pesque setup
```

It writes `.env` (the hostname and mode), pulls the image, and prints the host
record and the handle record with the DID the account was minted with. The stack
announces itself to the Bluesky relay (`PDS_CRAWLER` defaults to
`https://bsky.network`); set `PDS_CRAWLER` in `.env` to change or clear it. After
DNS propagates:

```bash
scripts/pesque doctor    # the preflight below, run for you
scripts/pesque account --handle alice.example.com --email alice@example.com
scripts/pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
scripts/pesque update    # pull the new image and restart
scripts/pesque logs      # follow the server logs
```

`scripts/pesque account` and `migrate` prompt for the password when `PASSWORD` is
not set, so it does not land in your shell history. Set `PESQUE_BUILD=1` to build
the image from source instead of pulling it.

The image carries a release, not Mix, so the mix tasks in this guide do not run
inside the container; `scripts/pesque` uses the release equivalents.

### Docker without Compose

`scripts/pesque` also drives a single container you already run, no compose file
and no Caddy. It picks that mode when there is no `docker-compose.yml` beside
it, or when `PESQUE_BACKEND=docker` is set. Point it at the container and image:

```bash
PESQUE_BACKEND=docker PESQUE_CONTAINER=pesque scripts/pesque doctor
```

The one-off tasks (`doctor`, `account`, `migrate`) run in a throwaway container
from the same image: `docker run --volumes-from` shares the running container's
data volume and the running container's `PDS_*` environment is mirrored in, so
the task reads the same state the live server does. `setup` writes a
`pesque.conf` and prints how to mount it; it does not start anything, because
the container belongs to your service manager. `update` pulls the image and then
runs `PESQUE_RESTART_CMD`, which has to recreate the container, since a plain
restart keeps the old image:

```bash
PESQUE_RESTART_CMD='systemctl restart pesque' scripts/pesque update
```

Without the script the same task is one command. `-i` keeps stdin attached for
the migration's code prompt:

```bash
docker run --rm -i --volumes-from pesque \
  --env-file <(docker inspect pesque --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^PDS_') \
  -e PDS_SERVE=false ghcr.io/zeeetech/pesque:latest \
  /app/bin/pesque eval 'Pesque.Release.boot!(); Pesque.Doctor.run()'
```

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
  mode = "path_multi";
  identity = "plc";
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

The operator tasks are oneshot units against the same data directory:

```bash
systemctl start pesque-doctor
systemctl start pesque-account   # reads /var/lib/pesque/account.env
systemctl start pesque-migrate   # reads /var/lib/pesque/migrate.env
```

Create the env file first, so the password never lands in the Nix store:

```bash
install -m600 /dev/null /var/lib/pesque/migrate.env
$EDITOR /var/lib/pesque/migrate.env   # MIGRATE_OLD_PDS, MIGRATE_HANDLE, MIGRATE_EMAIL, MIGRATE_PASSWORD
```

`MIGRATE_PASSWORD` is the account password, not an app password: the move needs
a full-access session, which an app password never carries.

The move stops at the PLC step for a code emailed to the account holder, and a
oneshot has no terminal to prompt on, so `pesque-migrate` is started twice: the
first start emails the code, then `MIGRATE_PLC_TOKEN` is added to the env file
and the second start completes the move. See
[Migration](migration.md#on-nixos).

The server speaks plain HTTP and expects a TLS proxy, exactly as in Docker.
`services.pesque.openFirewall` is off by default: the port should be reachable
only by the proxy on the same host or a tunnel.

## Behind a TLS proxy

Required for federation, and required for the rate limits to mean anything
(see [Operations](operations.md#rate-limits-and-the-proxy)).

```caddyfile
pds.example.com {
	reverse_proxy 127.0.0.1:4000
}
```

nginx needs the same proxy, plus `proxy_http_version 1.1`, the `Upgrade` and
`Connection` headers, `proxy_read_timeout 3600s` and `proxy_buffering off`,
because the firehose stays open indefinitely. `Connection` needs a
`map $http_upgrade $connection_upgrade { default upgrade; '' close; }` at the
`http` level.

## Configuration

Every knob can be set as an environment variable or in a `pesque.conf` file. The
environment wins, then the file, then the default; an invalid value fails at boot
instead of falling back silently. `config/runtime.exs` is the reference for names,
defaults and validation.

The file is plain `key = value`, one per line, `#` for comments. The key is the
variable without the `PDS_` prefix, lowercased: `hostname = pds.example.com` is
`PDS_HOSTNAME`. A key the server does not know is an error, so a typo fails boot
instead of being ignored. `pesque.conf.example` is the starting point.

The server reads `PDS_CONFIG`, or `pesque.conf` in the working directory. In the
container the path is `/data/pesque.conf`, inside the `pesque-data` volume, and a
raw `docker run` binds it directly:

```bash
docker run -d --name pesque -p 4000:4000 \
  -v pesque-data:/data \
  -v "$PWD/pesque.conf:/data/pesque.conf" \
  pesque
```

The compose stack does not mount a `pesque.conf` for you. It passes a fixed set
of settings (`PDS_HOSTNAME`, `PDS_MODE`, `PDS_CRAWLER`) read from `.env`, and
everything else comes from the defaults. To configure it with a file instead,
put the file on the volume and restart:

```bash
docker compose cp pesque.conf pesque:/data/pesque.conf
docker compose restart pesque
```

| Variable | Key in the file | Default | Purpose |
| --- | --- | --- | --- |
| `PDS_DATA_DIR` | `data_dir` | `data` | Directory holding the entire server state |
| `PDS_HOSTNAME` | `hostname` | `localhost` | Public hostname. Drives the DID, the DID document and every advertised URL |
| `PDS_MODE` | `mode` | `conformant_single` | `conformant_single` or `path_multi`. See [Identity](identity.md) |
| `PDS_IDENTITY` | `identity` | derived from mode | `web` or `plc`. `plc` under `path_multi`, `web` under `conformant_single` |
| `PDS_HANDLE_DOMAIN` | `handle_domain` | hostname | The domain accounts get handles under |
| `PDS_HANDLE` | `handle` | hostname | The handle the server publishes under `conformant_single` |
| `PDS_PORT` | `port` | `4000` | Port the process binds |
| `PDS_URL_SCHEME` | `url_scheme` | `https` | What the server tells the world to fetch |
| `PDS_URL_PORT` | `url_port` | `443` (`port` for http) | The advertised port |
| `PDS_REGISTRATION` | `registration` | `closed` | `open`, or invite codes |
| `PDS_PLC_DIRECTORY` | `plc_directory` | `https://plc.directory` | PLC directory, read only when `identity = plc` |
| `PDS_CRAWLER` | `crawler` | empty | Comma-separated relay base URLs to announce the server to at boot |
| `PDS_BLOB_UPLOAD_LIMIT` | `blob_upload_limit` | `5242880` (5 MiB) | Largest blob `uploadBlob` accepts, reported in `describeServer.blobUploadLimit` |
| `PDS_REPO_IMPORT_LIMIT` | `repo_import_limit` | `104857600` (100 MiB) | Largest `importRepo` body |
| `PDS_ADMIN_DIDS` | `admin_dids` | empty | Extra DIDs allowed to call `createInviteCodes` under `path_multi` |

`port` is where the process binds; `url_scheme` and `url_port` are what it
advertises. Behind a proxy, listening on 4000 and advertising 443 is correct.
`hostname` and `handle_domain` are often the same and rarely should be: a server
at `pds.example.com` can hand out `alice.example.com` handles.

## Create an account

Registration is closed by default, so the first account comes from the mix task,
which skips the invite requirement:

```bash
export PESQUE_PASSWORD=secret123

mix pesque.create_account \
  --handle alice.example.com \
  --email alice@example.com \
  --password-env PESQUE_PASSWORD
```

`--password secret123` works but lands in your shell history and in `ps`. Give
neither and the task prompts with echo off. Later accounts need an invite code,
minted through `com.atproto.server.createInviteCodes` and spent once, in the same
transaction that inserts the account. `PDS_REGISTRATION=open` drops the
requirement. On a `path_multi` server, minting codes also needs `PDS_ADMIN_DIDS`
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
