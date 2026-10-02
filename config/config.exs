import Config

config :pesque, ecto_repos: [Pesque.Repo]

config :pesque, PesqueWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PesqueWeb.ErrorJSON], layout: false]

config :phoenix, :json_library, JSON

config :logger, level: :info
config :logger, :console, format: "$time [$level] $message\n"
