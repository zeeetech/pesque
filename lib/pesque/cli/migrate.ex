defmodule Pesque.Cli.Migrate do
  @moduledoc """
  Moves an existing ATProto account onto this server, automating the
  scriptable half of the migration guide. The move stops at the identity
  step for a code the account holder receives by email: pass `--plc-token`
  (or set `MIGRATE_PLC_TOKEN`) on the second run.
  """

  use Gettext, backend: PesqueWeb.Gettext

  alias Pesque.Cli.Input
  alias Pesque.Cli.Report
  alias Pesque.Migrate
  alias Pesque.Release

  @usage """
  usage: pesque migrate --old-pds URL --handle H --email E [--plc-token T]

  The password (the old PDS account password, not an app password) comes
  from a no-echo prompt or a line on stdin, never a flag or the environment.
  Without --plc-token or MIGRATE_PLC_TOKEN, the move asks the old PDS to
  email the operation code and stops; run it again with the code to finish.
  """

  @switches [
    old_pds: :string,
    handle: :string,
    email: :string,
    plc_token: :string
  ]

  def run(argv) do
    with {:ok, opts, []} <- Input.options(argv, @switches, @usage),
         {:ok, old_pds} <- Input.text(opts, :old_pds, "MIGRATE_OLD_PDS", "old pds: "),
         {:ok, handle} <- Input.text(opts, :handle, "MIGRATE_HANDLE", "handle: "),
         {:ok, email} <- Input.text(opts, :email, "MIGRATE_EMAIL", "email: "),
         {:ok, password} <- Input.password("Password for the account: "),
         :ok <- Release.boot!() do
      base = [old_pds: old_pds, handle: handle, email: email, password: password]

      case plc_token(opts) do
        {:ok, token} ->
          case Migrate.run(base ++ [plc_token: token]) do
            :ok ->
              IO.puts("migration complete")
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        :no_value ->
          request_plc_code(base, handle)
      end
    end
  end

  defp plc_token(opts) do
    case opts[:plc_token] || System.get_env("MIGRATE_PLC_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :no_value
    end
  end

  defp request_plc_code(base, handle) do
    case Migrate.request_plc_code(base) do
      :ok ->
        IO.puts(gettext("a PLC operation code was emailed to %{handle}", handle: handle))

        [gettext("run pesque migrate --plc-token <code> (or set MIGRATE_PLC_TOKEN) to finish")]
        |> Report.next_steps()
        |> IO.puts()

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
