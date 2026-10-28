import Config

if config_env() == :dev do
  config :pesque, Pesque.Config.source_config!()
end

if config_env() == :test do
  Pesque.Release.prepare()
end

if config_env() == :prod do
  config :pesque, PesqueWeb.Endpoint, server: System.get_env("PHX_SERVER") == "true"
end
