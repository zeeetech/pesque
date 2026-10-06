import Config

# $metadata renders nothing unless the formatter selects keys, and the default
# selects none. The list is ours rather than :all because :all also drags in
# mfa, file, line and domain on every line, which buries the fields a log
# reader is actually looking for. Add a key here when you attach a new one.
config :logger, :default_formatter,
  format: "$time [$level] $message $metadata\n",
  metadata: [:did, :handle, :route, :reason, :hostname, :mode, :registration, :data_dir]

config :logger, :default_handler, level: :info

config :pesque, PesqueWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PesqueWeb.ErrorJSON], layout: false]

config :pesque, ecto_repos: [Pesque.Repo]

config :phoenix, :json_library, JSON

# The same library for the adapter, which defaults to Jason to store its array
# and map columns as JSON. Jason is not a dependency here.
config :ecto_sqlite3, :json_library, JSON
