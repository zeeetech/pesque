defmodule Pesque.Release do
  @moduledoc """
  Persistent preparation and database tasks for a release.

  Preparation runs before the server starts. It uses the configuration already
  installed by `Pesque.Config`; it never reads or installs configuration itself.
  """

  @app :pesque

  @doc """
  Creates the installation a server needs before it can boot.

  Repeatable: an existing secret, identity key, OAuth key, database or data
  directory is reused rather than replaced.
  """
  def prepare do
    Pesque.Storage.init!()
    Pesque.Storage.ensure_server_secret!()
    Pesque.Identity.ensure!()

    case Pesque.OAuth.Keys.ensure() do
      {:ok, _key} -> :ok
      {:error, reason} -> raise "the oauth signing key could not be prepared: #{inspect(reason)}"
    end

    migrate()
  end

  @doc "Runs every pending migration. Database only."
  def migrate do
    load_app()
    File.mkdir_p!(Pesque.data_dir())

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls a repository back to `version`. Database only."
  def rollback(repo, version) do
    load_app()

    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
