import Config

if config_env() != :test do
  config :pesque, Pesque.Repo,
    journal_mode: :wal,
    busy_timeout: 5_000,
    migration_lock: nil
end

if config_env() == :dev do
  config :pesque, Pesque.Config.source_config!()
end

if config_env() == :prod do
  config :pesque, Pesque.Repo, pool_size: 4

  config :pesque, PesqueWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      websocket_options: [
        max_frame_size: 1_048_576,
        max_fragmented_message_size: 1_048_576
      ]
    ],
    server: System.get_env("PHX_SERVER") == "true"
end
