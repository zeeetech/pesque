import Config

test_dir = Path.join(System.tmp_dir!(), "pesque-test")

config :pesque, Pesque.Repo,
  database: Path.join(test_dir, "pesque.db"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :pesque, PesqueWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  url: [host: "localhost", port: 4002, scheme: "http"],
  server: false

config :pesque,
  data_dir: test_dir,
  hostname: "localhost",
  port: 4002,
  public_url: "http://localhost:4002",
  handle_domain: "localhost",
  mode: :single,
  registration: :closed,
  crawlers: [],
  plc_directory: "https://plc.directory",
  lexicon_aggregator: nil,
  blob_max_bytes: 5_242_880,
  repo_import_max_bytes: 104_857_600,
  proxy_timeout: 15_000,
  proxy_response_limit: 10_485_760,
  admin_dids: [],
  privacy_policy_url: "",
  terms_of_service_url: ""

config :logger, level: :warning

config :pesque, argon2_opts: [t_cost: 1, m_cost: 8]

config :pesque,
  plc_client: Pesque.Plc.LocalDirectory,
  did_resolver_directory: Pesque.Plc.LocalDirectory

config :phoenix, :plug_init_mode, :runtime
