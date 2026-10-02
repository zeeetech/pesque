import Config

# Configure your database
config :pesque, Pesque.Repo,
  database: Path.expand("../pesque_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :pesque, PesqueWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "cfor3CGz69GETfQDZH/S+oIL9agFJwvH0HfCOosj0s4moOYIPoRHr0V4Pe6BYTJT",
  watchers: []

# Enable dev routes for dashboard and mailbox
config :pesque, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
