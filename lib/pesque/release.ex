defmodule Pesque.Release do
  @moduledoc "Release support: task bootstrap, the boot-time migration, and the account printer."

  use Gettext, backend: PesqueWeb.Gettext

  alias Pesque.Cli.Report

  @doc """
  Starts the application for a one-off release task.

  A release `eval` boots the VM but does not start the applications, so a task
  that reads the server identity or touches the database has to ask for them
  first. The endpoint stays down: a task runs against the data directory the
  live server already holds, and binding the port would fail.
  """
  def boot! do
    Application.put_env(:pesque, :serve, false)

    case Application.ensure_all_started(:pesque) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "the application could not start: #{inspect(reason)}"
    end
  end

  def migrate do
    if Process.whereis(Pesque.Repo) do
      run()
    else
      {:ok, _, _} = Ecto.Migrator.with_repo(Pesque.Repo, fn _repo -> run() end)
      :ok
    end
  end

  @doc """
  Prints the account and what to do next, the part of account creation the
  account verbs share. The steps after the account exist render through the
  shared next-steps block (`Pesque.Cli.Report`).
  """
  def print_account(account) do
    IO.puts("")

    [
      gettext("Account created.") <> "\n  handle  #{account.handle}\n  did     #{account.did}",
      gettext(
        "Point this domain at the server, then add the handle record, and give DNS a few minutes to catch up:"
      ) <>
        "\n\n" <> Enum.join(dns_lines(account), "\n"),
      gettext("Check that everything is reachable from outside:") <> "\n\n  pesque doctor"
    ]
    |> Report.next_steps()
    |> IO.puts()
  end

  # A did:web account serves its own handle at /.well-known/atproto-did, so
  # only the host record is needed. A multi account is resolved at
  # _atproto.<handle>, which nothing else publishes, so the TXT carries the
  # DID the directory minted.
  defp dns_lines(%{did: "did:plc:" <> _} = account) do
    [host_line(), "  _atproto.#{account.handle}   TXT    \"did=#{account.did}\""]
  end

  defp dns_lines(_account), do: [host_line()]

  defp host_line do
    ip =
      case System.get_env("PDS_PUBLIC_IP") do
        nil -> "<this server's public IP>"
        "" -> "<this server's public IP>"
        value -> value
      end

    "  #{Pesque.hostname()}   A      #{ip}"
  end

  defp run do
    path = Path.join(:code.priv_dir(:pesque), "repo/migrations")
    Ecto.Migrator.run(Pesque.Repo, path, :up, all: true)
  end
end
