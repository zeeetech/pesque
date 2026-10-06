import Config

data_dir = System.get_env("PDS_DATA_DIR", if(config_env() == :test, do: "tmp/test", else: "data"))
hostname = System.get_env("PDS_HOSTNAME", "localhost")
handle = System.get_env("PDS_HANDLE", hostname)

port =
  case Integer.parse(System.get_env("PDS_PORT", "4000")) do
    {n, ""} when n > 0 and n <= 65_535 ->
      n

    _ ->
      raise "PDS_PORT must be an integer between 1 and 65535, got: #{System.get_env("PDS_PORT")}"
  end

# The advertised URL defaults to https on 443 because the container speaks
# plain HTTP and is meant to sit behind a TLS proxy. For a local prod-like
# run with no proxy, set PDS_URL_SCHEME=http (port then defaults to PDS_PORT).
url_scheme =
  case System.get_env("PDS_URL_SCHEME", "https") do
    "https" -> "https"
    "http" -> "http"
    other -> raise "PDS_URL_SCHEME must be http or https, got: #{other}"
  end

url_port =
  case System.get_env("PDS_URL_PORT") do
    nil ->
      if url_scheme == "https", do: 443, else: port

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 and n <= 65_535 -> n
        _ -> raise "PDS_URL_PORT must be an integer between 1 and 65535, got: #{raw}"
      end
  end

mode =
  case System.get_env("PDS_MODE", "conformant_single") do
    "conformant_single" -> :conformant_single
    "path_multi" -> :path_multi
    other -> raise "PDS_MODE must be conformant_single or path_multi, got: #{other}"
  end

# PDS_HANDLE goes away with multi-account, so until then it is what
# conformant_single publishes, and path_multi ignores it.
handle_domain =
  System.get_env("PDS_HANDLE_DOMAIN", if(mode == :path_multi, do: hostname, else: handle))

admin_dids =
  "PDS_ADMIN_DIDS"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

registration =
  case System.get_env("PDS_REGISTRATION", "closed") do
    "open" -> :open
    "closed" -> :closed
    other -> raise "PDS_REGISTRATION must be open or closed, got: #{other}"
  end

# Raising rather than falling back, like PDS_PORT above: a blob limit that
# silently reads as something other than what was configured is a limit nobody
# chose.
blob_max_bytes =
  case System.get_env("PDS_BLOB_UPLOAD_LIMIT", "5242880") do
    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> raise "PDS_BLOB_UPLOAD_LIMIT must be a positive integer, got: #{raw}"
      end
  end

# Same rule as the blob limit: a cap that silently reads as something other
# than what was configured is a limit nobody chose.
repo_import_max_bytes =
  case System.get_env("PDS_REPO_IMPORT_LIMIT", "104857600") do
    raw ->
      case Integer.parse(raw) do
        {n, ""} when n > 0 -> n
        _ -> raise "PDS_REPO_IMPORT_LIMIT must be a positive integer, got: #{raw}"
      end
  end

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
    websocket: [max_frame_size: 1_048_576, max_fragmented_message_size: 1_048_576]
  ],
  url: [host: hostname, scheme: url_scheme, port: url_port],
  server: true

config :pesque,
  data_dir: data_dir,
  mode: mode,
  hostname: hostname,
  handle_domain: handle_domain,
  handle: handle,
  port: port,
  registration: registration,
  blob_max_bytes: blob_max_bytes,
  repo_import_max_bytes: repo_import_max_bytes,
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
