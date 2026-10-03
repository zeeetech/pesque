defmodule Pesque.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Pesque.Storage.init!()
    Pesque.Secret.load!()
    Pesque.Identity.load!()

    children = [
      Pesque.Repo,
      Pesque.BootMigrator,
      {Registry, keys: :duplicate, name: Pesque.EventRegistry},
      {Registry, keys: :unique, name: Pesque.RepoRegistry},
      Pesque.RepoSupervisor,
      PesqueWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pesque.Supervisor)
  end
end
