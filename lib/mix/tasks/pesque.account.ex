defmodule Mix.Tasks.Pesque.Account do
  @shortdoc "Account verbs: create, list, delete, takedown, activate, reset-password, plc-token"

  @moduledoc """
  The account verbs, the same code `bin/pesque account` runs.

      mix pesque.account create --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD
      mix pesque.account list
      mix pesque.account delete --handle alice.example.com
      mix pesque.account reset-password --did did:plc:...
      mix pesque.account plc-token --did did:plc:...

  Input order is the flag, then the conventional environment, then a prompt.
  For `create`, `--password VALUE` is a dev convenience for throwaway local
  accounts (the value lands in your shell history and in `ps`): the task sets
  it as the environment variable the verb reads and dispatches an argv with
  no password in it.
  """

  use Mix.Task

  @impl Mix.Task
  def run(["create" | argv]) do
    Mix.Pesque.run_with_password(["account", "create" | argv], "ACCOUNT_PASSWORD")
  end

  def run(argv), do: Mix.Pesque.run(["account" | argv])
end
