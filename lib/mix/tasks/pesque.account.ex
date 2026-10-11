defmodule Mix.Tasks.Pesque.Account do
  @shortdoc "Account verbs: create, list, delete, takedown, activate, reset-password"

  @moduledoc """
  The account verbs, the same code `bin/pesque account` runs.

      mix pesque.account create --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD
      mix pesque.account list
      mix pesque.account delete --handle alice.example.com
      mix pesque.account reset-password --did did:plc:...

  Input order is the flag, then the conventional environment
  (ACCOUNT_HANDLE, ACCOUNT_EMAIL, ACCOUNT_PASSWORD), then a prompt. There is
  no `--password` flag: a value there lands in shell history and `ps`.

  Runs with the endpoint not serving, so it works against a data directory
  the live server already has open instead of failing on the port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["account" | argv])
end
