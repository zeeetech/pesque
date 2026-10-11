defmodule Mix.Tasks.Pesque.Account do
  @shortdoc "Account verbs: create, list, delete, takedown, activate, reset-password"

  @moduledoc """
  The account verbs, the same code `bin/pesque account` runs.

      mix pesque.account create --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD
      mix pesque.account list
      mix pesque.account delete --handle alice.example.com
      mix pesque.account reset-password --did did:plc:...

  Input order is the flag, then the conventional environment
  (ACCOUNT_HANDLE, ACCOUNT_EMAIL, ACCOUNT_PASSWORD), then a prompt.

  For `create`, the password precedence is: `--password VALUE` wins over
  `--password-env NAME`, which wins over a no-echo prompt. The flag is dev
  convenience for throwaway local accounts - the value lands in your shell
  history and in `ps` - and it never reaches the verb layer: this task sets
  it as the environment variable the verb reads and dispatches an argv with
  no password in it.

  Runs with the endpoint not serving, so it works against a data directory
  the live server already has open instead of failing on the port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["create" | argv]) do
    Mix.Pesque.run_with_password(["account", "create" | argv], "ACCOUNT_PASSWORD")
  end

  def run(argv), do: Mix.Pesque.run(["account" | argv])
end
