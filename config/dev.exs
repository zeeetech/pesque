import Config

config :pesque, Pesque.Repo,
  database: "data/pesque.db",
  journal_mode: :wal,
  busy_timeout: 5_000,
  migration_lock: nil,
  pool_size: 4

config :pesque, PesqueWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  server: true

config :pesque,
  plc_client: Pesque.Plc.LocalDirectory,
  did_resolver_directory: Pesque.Plc.LocalDirectory

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
