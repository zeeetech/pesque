defmodule Pesque.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Pesque.Storage.init!()
    Pesque.Secret.load!()
    Pesque.Identity.load!()
    Pesque.Lexicon.Registry.reload()
    Pesque.Release.migrate()

    # Resolving the secret reads (or creates) data/server.secret. Doing it
    # here rather than in config/runtime.exs keeps everyday mix tasks from
    # touching the data directory; only an app boot does.
    endpoint = Application.get_env(:pesque, PesqueWeb.Endpoint, [])

    Application.put_env(
      :pesque,
      PesqueWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, Pesque.Secret.get())
    )

    children = [
      Pesque.Repo,
      Pesque.RateLimit,
      {Registry, keys: :duplicate, name: Pesque.EventRegistry},
      {Registry, keys: :unique, name: Pesque.RepoRegistry},
      Pesque.RepoSupervisor,
      Pesque.EventReaper,
      PesqueWeb.Endpoint
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Pesque.Supervisor) do
      log_boot()
      {:ok, pid}
    end
  end

  # The four things worth knowing when a server comes back wrong are which
  # data directory it opened, which hostname it publishes, which mode it is
  # in and where it is listening. Everything else in the answer to "why is it
  # not working" starts with those.
  defp log_boot do
    Logger.info("pesque up",
      data_dir: Pesque.data_dir(),
      hostname: Pesque.hostname(),
      mode: Pesque.mode(),
      registration: Pesque.registration()
    )
  end
end
