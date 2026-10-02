import Config

data_dir = System.get_env("PDS_DATA_DIR", "data")
hostname = System.get_env("PDS_HOSTNAME", "localhost")
handle = System.get_env("PDS_HANDLE", hostname)

config :pesque, data_dir: data_dir, hostname: hostname, handle: handle

config :pesque, Pesque.Repo, journal_mode: :wal, busy_timeout: 5_000, migration_lock: nil

if System.get_env("PHX_SERVER") do
  config :pesque, PesqueWeb.Endpoint, server: true
end

config :pesque, PesqueWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path =
    data_dir ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/pesque/pesque.db
      """

  config :pesque, Pesque.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :pesque, PesqueWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
