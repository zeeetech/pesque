defmodule Pesque.MixProject do
  use Mix.Project

  def project do
    [
      app: :pesque,
      version: "1.15.3",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      releases: [
        pesque: [
          config_providers: [
            {Pesque.Config, {:system, "PDS_CONFIG"}}
          ]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Pesque.Application, []},
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.14"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.26"},
      {:argon2_elixir, "~> 4.1"},
      {:gettext, "~> 1.0"},
      {:websock_adapter, "~> 0.6"}
    ]
  end

  # The gettext check keeps the .pot from drifting: the catalog is generated
  # from the code, so a string that moved without a re-extract is a string the
  # translators never see. It runs after compile because extraction reads the
  # compiled call sites.
  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "gettext.extract --check-up-to-date",
        "test"
      ]
    ]
  end

  # test/support holds the test-only helper modules. Not shipped, not compiled
  # outside test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
