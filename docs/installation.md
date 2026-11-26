# Installation

Pesque supports two deployments of the same pinned OCI image: the Compose bundle on a Docker host and the NixOS module. Running from source is for development.

## Requirements and mode

- Docker is required for both deployment paths; Compose also needs Compose v2.
- Public federation needs a hostname and HTTPS. Pesque serves plain HTTP; TLS termination is the operator's responsibility ([TLS proxy](#behind-a-tls-proxy)).
- Source development needs Elixir 1.19+, OTP 28+ and a C toolchain for SQLite.

The server DID is always `did:web:<hostname>`. `mode` controls account topology:

| | `single` (default) | `multi` |
| --- | --- | --- |
| Accounts | One | Multiple, for a small community or a few accounts |
| Handle | Bare domain | `alice.example.com` |
| Default account DID | Server `did:web` | `did:plc` |
| Browser signup and migration pages | No | Yes |

Use `single` for one account on your domain. Choose `multi` for a small community, browser signups, or importing an account from another PDS. Accounts in `multi` use `did:plc`; `did:web` subdomain accounts are not supported. `account create --identity web|plc` chooses the DID method where allowed: `web` is the `single` default, `plc` the `multi` default, and `web` is rejected in `multi`. A `did:web` identity depends on your hostname; `did:plc` survives a hostname move but depends on the PLC directory and a rotation key in the data directory. Back up that directory.

## Docker Compose

Download `pesque-compose-<version>.tar.gz` and `SHA256SUMS` from the [latest release](https://github.com/zeeetech/pesque/releases/latest), verify, then unpack:

```bash
sha256sum -c SHA256SUMS
tar -xzf pesque-compose-<version>.tar.gz
cd pesque
./pesque init
$EDITOR pesque.conf
docker compose up --detach --wait
./pesque account create --handle pds.example.com --email alice@example.com
```

The bundle contains a release-pinned `compose.yaml`, the readable host command `pesque`, and `pesque.conf.example`. `init` writes `pesque.conf` and creates `backups/`, without overwriting existing configuration. State is in the `pesque-data` volume at `/data`; the config is mounted read-only. The service publishes `127.0.0.1:4000:4000` for a local proxy. If changing the host-side port, keep the container port equal to `port` in the config. The image runs non-root and includes a health check.

Run lifecycle commands in the bundle directory:

```bash
docker compose stop pesque
docker compose restart pesque
docker compose logs -f pesque
```

Updates are manual: unpack the new bundle over the deployment directory or change the image tag, then run `docker compose up --detach --wait`. The data volume and existing config remain. The `./pesque` command runs operator verbs in a temporary container against the same volume:

```bash
./pesque doctor                 # federation preflight
./pesque status
./pesque account list
./pesque invite create
./pesque config validate
./pesque backup                 # writes to ./backups
./pesque restore ARCHIVE_NAME   # server must be stopped
```

Every verb accepts `--help`. Account creation and migration prompt for a no-echo password or read it from stdin; they do not accept a password flag or environment variable.

## NixOS

The flake module runs the same pinned image under systemd, generates `pesque.conf`, and provides a configured `pesque` command:

```nix
{
  imports = [ pesque.nixosModules.default ];

  services.beam.containers.pesque = {
    enable = true;
    image = "ghcr.io/zeeetech/pesque:1.15.6";
    port = 4000;
    uid = 33333;
    gid = 33333;
  };

  services.pesque = {
    scheme = "https";
    hostname = "pds.example.com";
    mode = "multi";
    handleDomain = "example.com";
    crawler = [ "https://bsky.network" ];
    settings = {
      blob_upload_limit = "104857600";
    };
  };
}
```

Set an explicit image tag or digest; `latest` is refused. `scheme`, `hostname`, `mode`, `handleDomain`, `registration` and `crawler` become configuration keys; `settings` passes other Pesque settings through, including limits, legal links and `admin_dids`. Set `crawler` to relay base URLs to announce the server at boot. Run `sudo pesque doctor` as a federation preflight.

`services.beam.containers` (from `beam-overlay`) owns the image, UID/GID, storage, published port and systemd lifecycle. Docker is enabled by default. `port` is the container and host port, not the public port. With a public hostname, the origin uses the scheme's default port, so a proxy on 443 forwarding to port 4000 advertises `https://pds.example.com`. A loopback or private hostname includes the port.

`services.beam.containers.pesque.dataDir` defaults to `/var/lib/pesque` on the host and is mounted at `/data`; the container config always uses `/data`. `services.pesque.backupDir` defaults to `dataDir/backups`. `uid` and `gid` have no defaults; when adopting existing data, set them to its owner. The module does not chown existing state. `requiredMounts` lists paths that must already be mountpoints, such as a ZFS dataset; the service and one-off commands check them before touching data. Pesque does not mount or chown them.

```bash
sudo systemctl start pesque
sudo systemctl stop pesque
journalctl -u pesque -f
sudo pesque account create --handle alice.example.com --email alice@example.com
sudo pesque backup
sudo systemctl start pesque-backup
```

The command uses one-off containers and needs Docker access. Updates are manual: set a new pinned image and run `nixos-rebuild switch`. The default `listenAddress` is `127.0.0.1`; the server still needs an operator-managed TLS proxy.

## From source

For development only:

```bash
mix deps.get
cat > pesque.conf <<'EOF'
url_scheme = http
hostname = localhost
port = 4000
data_dir = data
EOF
mix run --no-start -e 'Enum.each(Pesque.Config.source_config!(), fn {k, v} -> Application.put_env(:pesque, k, v) end); Pesque.Release.prepare()'
mix phx.server
```

Startup does not create state. `Pesque.Release.prepare/0` creates the data directory, secret, signing and OAuth keys, and database; it reuses existing material. No `mix ecto.create` or manually generated secret is needed. Operator verbs run with `mix run -e 'Pesque.Cli.main()' account create ...`; this boots the endpoint too, then exits when the verb finishes. Development and test configs use a local PLC directory. Releases and browser flows use the public PLC directory.

## Behind a TLS proxy

Federation requires HTTPS. Rate limits also use `x-forwarded-for`, so a directly reachable server without a trusted proxy has ineffective per-address limits. Pesque ships no proxy or certificates; operators configure TLS and forward to its plain HTTP listener. See [rate limits](operations.md#rate-limits-and-proxy).

In `multi`, handles use subdomains. Caddy can issue on demand and check each requested name against Pesque before issuance. `GET /xrpc/_tls-check?domain=<name>` returns 200 for the server hostname and hosted handles, otherwise 403. This endpoint is public by design, reveals only whether a name is hosted and uses the read budget. Point the hostname and wildcard DNS at the server. A separate handle domain needs its own Caddy site label:

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

nginx needs HTTP/1.1, `Upgrade`/`Connection` headers, `proxy_read_timeout 3600s` and `proxy_buffering off` for the long-lived firehose. Define `$connection_upgrade` with a `map` in the `http` block. nginx does not issue certificates on demand; `multi` needs wildcard DNS and a certificate covering `*.<hostname>`.

## Configuration

`PDS_CONFIG` selects the config file. Containers use `/data/pesque.conf`; otherwise the working directory's `pesque.conf` is used. There are no per-setting environment variables. Unknown or retired keys fail boot.

The file is `key = value`, with `#` comments. These four keys are required:

```ini
url_scheme = https
hostname = pds.example.com
port = 4000
data_dir = /data
```

`hostname` and `url_scheme` define the public origin. `port` is the listener port; behind a proxy it is not advertised. For local development, use `url_scheme = http`, `hostname = localhost`, `port = 4000`, and `data_dir = data`. Unset `handle_domain` defaults to `hostname`; set it separately for handles such as `alice.example.com`. In `single`, it is also the account's handle.

| Key | Default | Purpose |
| --- | --- | --- |
| `url_scheme` | required | `http` or `https`; client-facing scheme |
| `hostname` | required | Public hostname for DID, DID document and advertised URLs |
| `port` | required | Listener port; public only for loopback/private hosts |
| `data_dir` | required | Database, keys, blobs and secret |
| `mode` | `single` | `single` or `multi`; see [mode](#requirements-and-mode) |
| `handle_domain` | `hostname` | Domain for account handles |
| `registration` | `closed` | `open` allows signup; `closed` requires an invite |
| `crawler` | empty | Comma-separated relay base URLs announced at boot |
| `plc_directory` | `https://plc.directory` | Directory for newly minted `did:plc` accounts |
| `lexicon_aggregator` | empty | HTTPS base URL for non-vendored permission sets |
| `blob_upload_limit` | `5242880` (5 MiB) | Max `uploadBlob` size; advertised by `describeServer` |
| `repo_import_limit` | `104857600` (100 MiB) | Max `importRepo` request body |
| `sync_blocks_limit` | `50000000` (50,000,000 bytes) | Max combined `getBlocks` payload |
| `firehose_replay_limit` | `52428800` (50 MiB) | Max replay event payload per connection |
| `firehose_pending_frame_limit` | `100` | Pending live frames plus incoming frame per connection |
| `firehose_pending_byte_limit` | `52428800` (50 MiB) | Pending live bytes plus incoming frame per connection |
| `firehose_connection_rate_limit` | `5` | New `subscribeRepos` connections per IP per minute |
| `firehose_ip_connection_limit` | `4` | Concurrent firehose connections per IP |
| `firehose_global_connection_limit` | `64` | Concurrent firehose connections on the server |
| `proxy_timeout` | `15000` | Proxy call timeout before 504, in milliseconds |
| `proxy_response_limit` | `10485760` (10 MiB) | Max proxied response body |
| `admin_dids` | empty | Comma-separated DIDs allowed to call `createInviteCodes` in `multi` |
| `privacy_policy_url` | empty | Privacy page advertised by `describeServer`; unset omits it |
| `terms_of_service_url` | empty | Terms page advertised by `describeServer`; unset omits it |

Do not change `hostname` on a server with accounts: `did:web` is bound to it. Changing `handle_domain` does not rewrite stored handles. Run `pesque config validate` after config edits or release swaps; it uses the provider's validation and prints effective values.

## Create an account and verify

The operator can create accounts directly even when registration is closed:

```bash
./pesque account create --handle alice.example.com --email alice@example.com
```

Later browser signups need a one-use invite from `./pesque invite create`, unless `registration = open`. `createInviteCodes` is operator-only in `multi`; add your DID to `admin_dids`. Passwords use a no-echo prompt or stdin.

Check the server and federation in order:

```bash
./pesque doctor
curl -s http://localhost:4000/xrpc/_health
curl -s http://localhost:4000/xrpc/com.atproto.server.describeServer
curl -s https://pds.example.com/.well-known/did.json
curl -s "https://pds.example.com/xrpc/com.atproto.identity.resolveHandle?handle=alice.example.com"
```

`doctor` is the federation preflight; configure `crawler` to announce the server to relays. `_health` returns 200 when migrations and account reads work. If `did` is `localhost`, set the public hostname. Set legal URLs before using a real domain ([legal pages](operations.md#legal-pages)).

For an authenticated write and firehose smoke test, replace the handle and password below. This uses `jq` and `websocat`; the session response supplies both the token and the correct DID for `single` or `multi`:

```bash
SESSION=$(curl -s -X POST https://pds.example.com/xrpc/com.atproto.server.createSession \
  -H "content-type: application/json" \
  -d '{"identifier":"pds.example.com","password":"secret123"}')
ACCESS_JWT=$(printf '%s' "$SESSION" | jq -r .accessJwt)
DID=$(printf '%s' "$SESSION" | jq -r .did)
curl -s -X POST https://pds.example.com/xrpc/com.atproto.repo.createRecord \
  -H "authorization: Bearer $ACCESS_JWT" -H "content-type: application/json" \
  -d "{\"repo\":\"$DID\",\"collection\":\"app.bsky.feed.post\",\"record\":{\"\$type\":\"app.bsky.feed.post\",\"text\":\"hello from pesque\",\"createdAt\":\"2026-01-01T00:00:00Z\"}}"
```

Run `websocat "wss://pds.example.com/xrpc/com.atproto.sync.subscribeRepos"` in another terminal and write another record; a `#commit` frame should appear. A silent firehose usually means proxy buffering; identity that resolves locally only usually points to proxy or firewall configuration.

`did:web` needs a public HTTPS DID document. A `did:plc` document is served by the PLC directory, not Pesque.
