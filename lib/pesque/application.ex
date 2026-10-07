defmodule Pesque.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Pesque.Storage.init!()
    Pesque.Secret.load!()
    Pesque.Identity.load!()
    Pesque.OAuth.Keys.load!()
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

    children =
      [
        Pesque.Repo,
        Pesque.RateLimit,
        {Registry, keys: :duplicate, name: Pesque.EventRegistry},
        {Registry, keys: :unique, name: Pesque.RepoRegistry},
        Pesque.RepoSupervisor,
        Pesque.EventReaper
      ] ++ endpoint()

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Pesque.Supervisor) do
      log_boot()
      announce_to_relays()
      {:ok, pid}
    end
  end

  # A mix task that only talks to the database and the domain (create_account)
  # sets :serve to false, so it does not stand up an HTTP endpoint it never
  # answers a request on.
  defp endpoint do
    if Application.get_env(:pesque, :serve, true), do: [PesqueWeb.Endpoint], else: []
  end

  # A relay that is slow or down must not delay or fail this boot, so the crawl
  # requests go out in a task nobody waits on.
  defp announce_to_relays do
    if Pesque.crawlers() != [] do
      Task.start(fn -> Pesque.Crawl.request_all() end)
    end

    :ok
  end

  # The four things worth knowing when a server comes back wrong are which
  # data directory it opened, which hostname it publishes, which mode it is
  # in and where it is listening. Everything else in the answer to "why is it
  # not working" starts with those.
  defp log_boot do
    Logger.info("pesque up",
      data_dir: Pesque.data_dir(),
      hostname: Pesque.hostname(),
      base_url: Pesque.base_url(),
      mode: Pesque.mode(),
      registration: Pesque.registration()
    )

    Enum.each(boot_warnings(), &Logger.warning/1)
  end

  # The failures a self-hoster actually hits are silent ones: the process comes
  # up and nothing can resolve it. Name them at boot rather than leaving a
  # client to discover them later.
  defp boot_warnings do
    hostname_warning() ++ scheme_warning() ++ registration_warning()
  end

  defp hostname_warning do
    if Pesque.hostname_is_ip?() do
      [
        "hostname #{Pesque.hostname()} is an IP literal: ATProto handles and did:web " <>
          "resolve through DNS, so this server is reachable but not resolvable. Point a " <>
          "domain at it and set hostname to that domain to federate."
      ]
    else
      []
    end
  end

  defp scheme_warning do
    if String.starts_with?(Pesque.base_url(), "http://") and Pesque.hostname() != "localhost" do
      [
        "the advertised base URL is #{Pesque.base_url()}, not HTTPS: the spec requires TLS " <>
          "for federation. Put a proxy in front and set url_scheme = https."
      ]
    else
      []
    end
  end

  defp registration_warning do
    if Pesque.registration() == :closed and Pesque.Accounts.empty?() do
      [
        "registration is closed and no account exists yet. Create the first one with:\n" <>
          "  mix pesque.create_account --handle <handle> --email <email> --password-env PASSWORD"
      ]
    else
      []
    end
  end
end
