import Config

data_dir = System.get_env("PDS_DATA_DIR", "data")
hostname = System.get_env("PDS_HOSTNAME", "localhost")
handle = System.get_env("PDS_HANDLE", hostname)
port = String.to_integer(System.get_env("PDS_PORT", "4000"))

config :pesque,
  data_dir: data_dir,
  hostname: hostname,
  handle: handle

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

if config_env() == :test do
  config :pesque, PesqueWeb.Endpoint, server: false
end
