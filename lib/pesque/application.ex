defmodule Pesque.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    operator_boot? = Application.get_env(:pesque, :operator_boot, false)

    Pesque.Secret.load!()
    Pesque.Identity.load!()
    Pesque.OAuth.Keys.load!()
    Pesque.Lexicon.Registry.reload()

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
        Pesque.OAuth.PermissionSets.Cache,
        {Registry, keys: :duplicate, name: Pesque.EventRegistry},
        {Registry, keys: :unique, name: Pesque.RepoRegistry},
        {Registry, keys: :unique, name: Pesque.Migrate.Registry},
        {Task.Supervisor, name: Pesque.Migrate.Supervisor},
        Pesque.RepoSupervisor
      ]

    children =
      if operator_boot? do
        children ++ endpoint()
      else
        children ++ [Pesque.EventReaper] ++ endpoint()
      end

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Pesque.Supervisor) do
      unless operator_boot? do
        reap_interrupted_moves()
        log_boot()
        announce_to_relays()
      end

      {:ok, pid}
    end
  end

  # A move runs in a task under Pesque.Migrate.Supervisor, so a restart took
  # it down with the node while its row still says it is running. This sweep
  # marks those failed. It cannot run earlier than here: the Repo is up by
  # now.
  defp reap_interrupted_moves do
    _ = Pesque.Migrate.Jobs.reap_interrupted()

    :ok
  end

  # A one-off task sets :serve to false, so it does not stand up an HTTP
  # endpoint it never answers a request on.
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

  # The four things worth knowing when a server comes back wrong: which data
  # directory it opened, which hostname it publishes, which mode it is in and
  # where it is listening.
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

  # The failures a self-hoster actually hits are silent ones: the process
  # comes up and nothing can resolve it. Name them at boot.
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
          "  pesque account create --handle <handle> --email <email>"
      ]
    else
      []
    end
  end
end
