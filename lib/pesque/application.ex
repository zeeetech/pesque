defmodule Pesque.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Pesque.Storage.init!()

    children = [
      Pesque.Repo,
      Pesque.BootMigrator,
      {Registry, keys: :duplicate, name: Pesque.EventRegistry},
      {Registry, keys: :unique, name: Pesque.RepoRegistry},
      Pesque.RepoSupervisor,
      Pesque.Identity,
      PesqueWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pesque.Supervisor)
  end
end
