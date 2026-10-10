defmodule Pesque.Release do
  @moduledoc "Release support: task bootstrap, the migration runner, and the first account."

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
  Creates the first account from `ACCOUNT_HANDLE`, `ACCOUNT_EMAIL` and
  `ACCOUNT_PASSWORD`, then prints what to do next.

  The release-friendly entry behind `scripts/pesque account`: the container
  image carries no Mix, so the wrapper calls this through `bin/pesque eval`
  rather than a mix task. Answers `:ok` or `:error`, and a caller that has to
  set an exit code can do it off the answer.
  """
  def create_account_from_env do
    case Pesque.Accounts.create_account(
           System.get_env("ACCOUNT_HANDLE"),
           System.get_env("ACCOUNT_EMAIL"),
           System.get_env("ACCOUNT_PASSWORD")
         ) do
      {:ok, account} ->
        print_account(account)
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Could not create the account: #{describe_error(reason)}")
        :error
    end
  end

  @doc """
  Runs the account move from the `MIGRATE_*` environment, the release-friendly
  entry behind `pesque-migrate`.

  The move stops at the PLC step for a code the account holder receives by
  email, and a systemd oneshot has no terminal to prompt on. So the step is
  split: with no `MIGRATE_PLC_TOKEN`, this asks the old PDS to email the code
  and returns; with the code set, it runs the move using it. Answers `:ok` or
  `:error` so a caller can set an exit code off the answer.
  """
  def migrate_from_env do
    opts = [
      old_pds: System.get_env("MIGRATE_OLD_PDS"),
      handle: System.get_env("MIGRATE_HANDLE"),
      email: System.get_env("MIGRATE_EMAIL"),
      password: System.get_env("MIGRATE_PASSWORD")
    ]

    case System.get_env("MIGRATE_PLC_TOKEN") do
      token when is_binary(token) and token != "" ->
        case Pesque.Migrate.run(opts ++ [plc_token: token]) do
          :ok ->
            IO.puts("migration complete")
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "migration failed: " <> describe_error(reason))
            :error
        end

      _ ->
        case Pesque.Migrate.request_plc_code(opts) do
          :ok ->
            IO.puts("a PLC operation code was emailed to the account holder")
            IO.puts("set MIGRATE_PLC_TOKEN in migrate.env, then run pesque-migrate again")
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "could not request the PLC code: " <> describe_error(reason))
            :error
        end
    end
  end

  @doc "Turns an error reason into a sentence a person running a command can act on."
  def describe_error(reason) do
    case reason do
      {:old_pds_status, status, message} ->
        "the old PDS answered #{status}: #{message}"

      {:old_pds_status, status} ->
        "the old PDS answered #{status}"

      {:old_pds_unreachable, detail} ->
        "the old PDS could not be reached: #{inspect(detail)}"

      :plc_code_missing ->
        "no PLC code was read; run this where the prompt can be answered, or set MIGRATE_PLC_TOKEN"

      :too_large ->
        "a blob is larger than this server accepts (#{Pesque.blob_max_bytes()} bytes); raise blob_upload_limit"

      :handle_not_available ->
        "that handle is already taken, or it is not under this server's handle domain"

      :account_exists ->
        "this server already has an account; conformant_single serves exactly one"

      :password_too_short ->
        "the password must be at least 8 characters"

      :email_required ->
        "an email address is required"

      :disallowed_handle ->
        "that handle is not allowed on this server"

      other ->
        inspect(other)
    end
  end

  defp print_account(account) do
    IO.puts("")
    IO.puts("Account created.")
    IO.puts("  handle  #{account.handle}")
    IO.puts("  did     #{account.did}")
    IO.puts("")
    IO.puts("Point this domain at the server, then add the handle record, and give")
    IO.puts("DNS a few minutes to catch up:")
    IO.puts("")
    Enum.each(dns_lines(account), &IO.puts/1)
    IO.puts("")
    IO.puts("Check that everything is reachable from outside:")
    IO.puts("")
    IO.puts("  scripts/pesque doctor")
  end

  # A did:web account is the server, which serves its own handle at
  # /.well-known/atproto-did, so only the host record is needed. A path_multi
  # account gets its handle resolved at _atproto.<handle>, which nothing else
  # publishes, so the TXT carries the DID the directory minted.
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
