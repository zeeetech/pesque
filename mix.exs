defmodule Pesque.MixProject do
  use Mix.Project

  def project do
    [
      app: :pesque,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Pesque.Application, []},
      extra_applications: [:logger, :crypto]
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
      {:ecto_sqlite3, ">= 0.0.0"},
      {:argon2_elixir, "~> 4.0"},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warnings-as-errors", "format", "test"]
    ]
  end
end
