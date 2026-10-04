import Config

data_dir = System.get_env("PDS_DATA_DIR", if(config_env() == :test, do: "tmp/test", else: "data"))
hostname = System.get_env("PDS_HOSTNAME", "localhost")
handle = System.get_env("PDS_HANDLE", hostname)
port = String.to_integer(System.get_env("PDS_PORT", "4000"))

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

registration =
  case System.get_env("PDS_REGISTRATION", "closed") do
    "open" -> :open
    "closed" -> :closed
    other -> raise "PDS_REGISTRATION must be open or closed, got: #{other}"
  end

config :pesque, Pesque.Repo,
  database: Path.join(data_dir, "pesque.db"),
  journal_mode: :wal,
  busy_timeout: 5_000,
  migration_lock: nil,
  pool_size: 4

config :pesque, PesqueWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: port],
  url: [host: hostname, scheme: "https", port: 443],
  secret_key_base: Pesque.Storage.server_secret!(data_dir),
  server: true

config :pesque,
  data_dir: data_dir,
  mode: mode,
  hostname: hostname,
  handle_domain: handle_domain,
  handle: handle,
  port: port,
  registration: registration

if config_env() == :test do
  config :pesque, Pesque.Repo, pool: Ecto.Adapters.SQL.Sandbox
  config :pesque, PesqueWeb.Endpoint, server: false

  # Logger.info from the boot sequence and from on_exit callbacks escapes
  # ExUnit's capture_log: the first runs before ExUnit.start, the second after
  # the capture scope closes. The level cuts both at the source.
  config :logger, level: :warning

  config :pesque, argon2_opts: [t_cost: 1, m_cost: 8]
end
