defmodule Pesque.MixProject do
  use Mix.Project

  def project do
    [
      app: :pesque,
      version: "1.11.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  # The release step keeps the stock bin/pesque as bin/pesque.core and installs
  # a wrapper that dispatches verb commands into Pesque.Cli.main().
  defp releases do
    [
      pesque: [
        steps: [:assemble, &Pesque.Mix.ReleaseSteps.cli/1]
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
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.6"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.25"},
      {:argon2_elixir, "~> 4.0"},
      {:gettext, "~> 1.0"},
      {:websock_adapter, "~> 0.5"}
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
