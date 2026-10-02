import Config

config :pesque,
  ecto_repos: [Pesque.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :pesque, PesqueWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PesqueWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pesque.PubSub,
  live_view: [signing_salt: "iuuF1DCp"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, JSON

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
