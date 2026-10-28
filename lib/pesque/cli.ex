defmodule Pesque.Cli do
  @moduledoc """
  Release-side verb dispatch: `bin/pesque <verb> <argv>` arrives here through
  one fixed eval, and the answer is the exit code alone: 0 ok, 1 domain
  failure, 2 usage. `run/1` answers `:ok | {:error, reason} | {:usage, text} |
  {:help, text}`, and the fourth is the pleasant one: a `--help` the verb
  asked for prints on stdout with exit 0. Mix tasks run the same verbs
  through `run/1`, which answers instead of halting, so tests exercise
  dispatch without leaving the VM.
  """

  alias Pesque.Cli.{
    Account,
    Backup,
    Config,
    Crawl,
    Doctor,
    Explain,
    Invite,
    Locale,
    Migrate,
    Restore,
    Status
  }

  @verbs ~w(account invite migrate doctor status backup restore config crawl)

  @doc "The verbs the release wrapper dispatches, in the order it names them."
  def verbs, do: @verbs

  @doc "The release entry: halts 0, 1 or 2 off the answer. Tests never call it."
  def main do
    case run(System.argv()) do
      :ok ->
        System.halt(0)

      {:help, text} ->
        IO.puts(text)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "error: " <> Explain.render(reason))
        System.halt(1)

      {:usage, text} ->
        IO.puts(:stderr, text)
        System.halt(2)
    end
  end

  @doc """
  Answers the verb: puts the CLI locale for the calling process, then
  dispatches. `main/0` and the mix tasks both come through here.
  """
  def run(argv) do
    Locale.put()
    dispatch(argv)
  end

  defp dispatch(["account" | rest]), do: Account.run(rest)
  defp dispatch(["invite" | rest]), do: Invite.run(rest)
  defp dispatch(["migrate" | rest]), do: Migrate.run(rest)
  defp dispatch(["doctor" | rest]), do: Doctor.run(rest)
  defp dispatch(["status" | rest]), do: Status.run(rest)
  defp dispatch(["backup" | rest]), do: Backup.run(rest)
  defp dispatch(["restore" | rest]), do: Restore.run(rest)
  defp dispatch(["config" | rest]), do: Config.run(rest)
  defp dispatch(["crawl" | rest]), do: Crawl.run(rest)
  defp dispatch([]), do: {:usage, usage()}
  defp dispatch([unknown | _]), do: {:usage, "unknown command: #{unknown}\n\n" <> usage()}

  @doc """
  The verb menu. The passwords line is the contract: no `--password VALUE`
  exists anywhere in this surface.
  """
  def usage do
    """
    usage: pesque <verb> [flags]

      account create --handle H --email E [--identity web|plc] [--public-ip IP]
      account list [--status active|deactivated] [--grep PATTERN]
      account show --did D | --handle H
      account delete --did D | --handle H [--dry-run]
      account takedown --did D | --handle H
      account activate --did D | --handle H
      account reset-password --did D | --handle H
      account plc-token --did D | --handle H
      account email-token --did D | --handle H
      account reset-token --did D | --handle H
      account app-passwords --did D | --handle H
      account revoke-app-password --did D | --handle H --name N
      invite create [--count N] [--uses N] [--for DID]
      migrate --old-pds URL --handle H --email E [--plc-token T]
      doctor
      status
      backup [--out DIR]
      restore (--archive PATH | PATH) [--dry-run]
      config validate
      config template [--out PATH]
      crawl request

    The read verbs (account list, account show, account app-passwords,
    status) take --json for machine-readable output on stdout; every verb
    takes --help for its usage.

    Passwords come from a no-echo prompt, or from a line on stdin so they
    can be piped, never argv or the environment.
    """
  end
end
