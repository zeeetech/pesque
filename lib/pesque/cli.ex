defmodule Pesque.Cli do
  @moduledoc """
  Release-side verb dispatch: `bin/pesque <verb> <argv>` arrives here through
  one fixed eval, and the answer is the exit code alone: 0 ok, 1 domain
  failure, 2 usage. Mix tasks run the same verbs through `run/1`, which
  answers instead of halting, so tests exercise dispatch without leaving the VM.
  """

  alias Pesque.Cli.{Account, Backup, Config, Crawl, Doctor, Health, Invite, Migrate, Restore}

  @verbs ~w(account invite migrate doctor backup restore config crawl health)

  @doc "The verbs the release wrapper dispatches, in the order it names them."
  def verbs, do: @verbs

  @doc "The release entry: halts 0, 1 or 2 off the answer. Tests never call it."
  def main do
    case run(System.argv()) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "error: " <> Pesque.Release.describe_error(reason))
        System.halt(1)

      {:usage, text} ->
        IO.puts(:stderr, text)
        System.halt(2)
    end
  end

  def run(["account" | rest]), do: Account.run(rest)
  def run(["invite" | rest]), do: Invite.run(rest)
  def run(["migrate" | rest]), do: Migrate.run(rest)
  def run(["doctor" | rest]), do: Doctor.run(rest)
  def run(["backup" | rest]), do: Backup.run(rest)
  def run(["restore" | rest]), do: Restore.run(rest)
  def run(["config" | rest]), do: Config.run(rest)
  def run(["crawl" | rest]), do: Crawl.run(rest)
  def run(["health" | rest]), do: Health.run(rest)
  def run([]), do: {:usage, usage()}
  def run([unknown | _]), do: {:usage, "unknown command: #{unknown}\n\n" <> usage()}

  @doc """
  The verb menu. The passwords line is the contract: no `--password VALUE`
  exists anywhere in this surface.
  """
  def usage do
    """
    usage: pesque <verb> [flags]

      account create --handle H --email E [--password-env VAR]
      account list
      account delete --did D | --handle H
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
      backup [--out DIR]
      restore (--archive PATH | PATH)
      config validate
      config template [--out PATH]
      crawl request
      health

    Passwords come from --password-env, the conventional environment
    (ACCOUNT_PASSWORD / MIGRATE_PASSWORD) or a no-echo prompt, never argv.
    """
  end
end
