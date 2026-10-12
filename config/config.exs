import Config

# $metadata renders nothing unless the formatter selects keys, and the default
# selects none. The list is ours rather than :all because :all also drags in
# mfa, file, line and domain on every line, which buries the fields a log
# reader is actually looking for. Add a key here when you attach a new one.
config :logger, :default_formatter,
  format: "$time [$level] $message $metadata\n",
  metadata: [
    :did,
    :handle,
    :token,
    :route,
    :reason,
    :path,
    :count,
    :records,
    :hostname,
    :mode,
    :registration,
    :data_dir
  ]

config :logger, :default_handler, level: :info

config :pesque, PesqueWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PesqueWeb.ErrorJSON], layout: false]

config :pesque, ecto_repos: [Pesque.Repo]

# The boot warnings speak to an operator of a real deployment: an IP hostname, a
# non-HTTPS base URL, a closed server with no account yet. Under test all three
# hold by construction, and the boot runs before ExUnit starts capturing, so
# they are off rather than printed as noise no test asked for.
config :pesque, boot_warnings: config_env() != :test

# The browser-facing pages only. Protocol text stays English, so gettext never
# touches the XRPC surface. Portuguese is the default because the server is
# self-hosted in Brazil, and English is the translation that keeps a page
# legible to the network at large.
config :pesque, PesqueWeb.Gettext,
  default_locale: "pt_BR",
  locales: ~w(pt_BR en)

config :phoenix, :json_library, JSON

# The same library for the adapter, which defaults to Jason to store its array
# and map columns as JSON. Jason is not a dependency here.
config :ecto_sqlite3, :json_library, JSON
