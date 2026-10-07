import Config

# Settings come from the environment first, then pesque.conf, then the defaults
# here. Pesque.Config.get/3 is the one place that order lives.
file = Pesque.Config.load!()
get = fn key, default -> Pesque.Config.get(file, key, default) end

data_dir = get.("data_dir", if(config_env() == :test, do: "tmp/test", else: "data"))
hostname = get.("hostname", "localhost")
handle = get.("handle", hostname)

port =
  case Integer.parse(get.("port", "4000")) do
    {n, ""} when n > 0 and n <= 65_535 ->
      n

    _ ->
      raise "port must be an integer between 1 and 65535, got: #{get.("port", "4000")}"
  end

# The advertised URL defaults to https on 443 because the container speaks
# plain HTTP and is meant to sit behind a TLS proxy. For a local prod-like
# run with no proxy, set url_scheme = http (the port then defaults to port).
url_scheme =
  case get.("url_scheme", "https") do
    "https" -> "https"
    "http" -> "http"
    other -> raise "url_scheme must be http or https, got: #{other}"
  end

url_port =
  case get.("url_port", nil) do
    nil ->
      if url_scheme == "https", do: 443, else: port

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 and n <= 65_535 -> n
        _ -> raise "url_port must be an integer between 1 and 65535, got: #{raw}"
      end
  end

mode =
  case get.("mode", "conformant_single") do
    "conformant_single" -> :conformant_single
    "path_multi" -> :path_multi
    other -> raise "mode must be conformant_single or path_multi, got: #{other}"
  end

# The DID method. Derived from the mode by default: a multi-account server
# mints did:plc because the official client expects it, and the single-account
# server is did:web of its own hostname. Set identity explicitly to override.
identity =
  case get.("identity", if(mode == :path_multi, do: "plc", else: "web")) do
    "web" -> :web
    "plc" -> :plc
    other -> raise "identity must be web or plc, got: #{other}"
  end

# path_multi hands handles to real clients, and the official client expects a
# did:plc account, so web there would mint accounts it cannot use.
if mode == :path_multi and identity == :web do
  raise "mode = path_multi requires identity = plc: the official client expects did:plc accounts"
end

# Only read when identity = plc. A directory the operator points at is a
# deployment choice, so it is configuration rather than a constant.
plc_directory = get.("plc_directory", "https://plc.directory")

# Relays to announce this server to at boot. Comma separated, empty by default:
# a relay also discovers PDS instances other ways, so an operator who names none
# still works.
crawlers =
  "crawler"
  |> then(&get.(&1, ""))
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

# handle goes away with multi-account, so until then it is what
# conformant_single publishes, and path_multi ignores it.
handle_domain = get.("handle_domain", if(mode == :path_multi, do: hostname, else: handle))

admin_dids =
  "admin_dids"
  |> then(&get.(&1, ""))
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

registration =
  case get.("registration", "closed") do
    "open" -> :open
    "closed" -> :closed
    other -> raise "registration must be open or closed, got: #{other}"
  end

# Raising rather than falling back, like port above: a blob limit that silently
# reads as something other than what was configured is a limit nobody chose.
blob_max_bytes =
  case get.("blob_upload_limit", "5242880") do
    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> raise "blob_upload_limit must be a positive integer, got: #{raw}"
      end
  end

# Same rule as the blob limit: a cap that silently reads as something other
# than what was configured is a limit nobody chose.
repo_import_max_bytes =
  case get.("repo_import_limit", "104857600") do
    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> raise "repo_import_limit must be a positive integer, got: #{raw}"
      end
  end

# The operator's own policy documents, advertised by describeServer. Empty by
# default: this server has no policy of its own, so it publishes none rather
# than linking a placeholder a client would show to users.
privacy_policy_url = get.("privacy_policy_url", "")
terms_of_service_url = get.("terms_of_service_url", "")

config :pesque, Pesque.Repo,
  database: Path.join(data_dir, "pesque.db"),
  journal_mode: :wal,
  busy_timeout: 5_000,
  migration_lock: nil,
  pool_size: 4

config :pesque, PesqueWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: port,
    # The firehose is server-push only, so no client frame is legitimate and
    # Bandit's defaults (8 MB a frame, 8 MB a fragmented message) are pure
    # attack surface: an unauthenticated socket would pay an inflate plus a
    # CBOR validate per frame before the handler refused it. 1 MB is generous
    # for a protocol where the client never speaks.
    websocket_options: [max_frame_size: 1_048_576, max_fragmented_message_size: 1_048_576]
  ],
  url: [host: hostname, scheme: url_scheme, port: url_port],
  server: true

config :pesque,
  data_dir: data_dir,
  mode: mode,
  identity: identity,
  plc_directory: plc_directory,
  crawlers: crawlers,
  hostname: hostname,
  handle_domain: handle_domain,
  port: port,
  registration: registration,
  blob_max_bytes: blob_max_bytes,
  repo_import_max_bytes: repo_import_max_bytes,
  privacy_policy_url: privacy_policy_url,
  terms_of_service_url: terms_of_service_url,
  # Whether to start the HTTP endpoint. A one-off task container
  # (create_account, doctor) sets this false so it does not fight the running
  # server for the port.
  serve: get.("serve", "true") != "false",
  # argon2's m_cost is an exponent of KiB, so the library default of 16 is 64
  # MiB of memory per hash. That is a defensible number on a box with room and
  # a fast way to OOM a small one: Accounts caps how many hashes run at once,
  # so the ceiling is this times that cap, and the cap alone does not make the
  # default safe. 12 is 4 MiB and still slow enough to be worth attacking.
  argon2_opts: [t_cost: 3, m_cost: 12],
  # Under :path_multi there is no account that is the server, so the operator
  # is named here. Empty means the server identity only, which under
  # :path_multi means nobody, which is deliberate: a closed server that admits
  # no one is fixed by adding one line, one that admits the first account to
  # ask is not fixed at all.
  admin_dids: admin_dids

if config_env() == :test do
  # Wider than the server's pool on purpose. The concurrency test checks out one
  # connection per writer while the test process holds one more, and a pool of
  # exactly that size deadlocks the harness rather than the server.
  config :pesque, Pesque.Repo, pool: Ecto.Adapters.SQL.Sandbox, pool_size: 12
  config :pesque, PesqueWeb.Endpoint, server: false

  # Logger.info from the boot sequence and from on_exit callbacks escapes
  # ExUnit's capture_log: the first runs before ExUnit.start, the second after
  # the capture scope closes. The level cuts both at the source.
  config :logger, level: :warning

  config :pesque, argon2_opts: [t_cost: 1, m_cost: 8]
end
