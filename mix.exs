defmodule Pesque.MixProject do
  use Mix.Project

  def project do
    [
      app: :pesque,
      version: "1.2.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
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
      {:bandit, "~> 1.6"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.25"},
      {:argon2_elixir, "~> 4.0"},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]
    ]
  end

  # test/support holds the test-only helper modules. Not shipped, not compiled
  # outside test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
