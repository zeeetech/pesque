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
    :data_dir,
    :request_id,
    :requester,
    :user_agent,
    :remote_ip,
    :repo,
    :collection,
    :body
  ]

config :logger, :default_handler, level: :info

config :pesque, PesqueWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PesqueWeb.ErrorJSON, html: PesqueWeb.ErrorHTML],
    layout: false
  ]

config :pesque, ecto_repos: [Pesque.Repo]

config :pesque, argon2_opts: [t_cost: 3, m_cost: 12]

# The browser-facing pages only. Protocol text stays English, so gettext never
# touches the XRPC surface. Portuguese is the default because the server is
# self-hosted in Brazil, and English is the translation that keeps a page
# legible to the network at large.
config :pesque, PesqueWeb.Gettext,
  default_locale: "pt_BR",
  locales: ~w(pt_BR en)

config :phoenix, :json_library, JSON

config :ecto_sqlite3, :json_library, JSON

if config_env() != :prod do
  import_config "#{config_env()}.exs"
end
