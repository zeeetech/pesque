defmodule Mix.Tasks.Pesque.Account do
  @shortdoc "Account verbs: create, list, show, delete, takedown, activate, reset-password, plc-token, email-token, reset-token"

  @moduledoc """
  The account verbs, the same code `bin/pesque account` runs.

      mix pesque.account create --handle alice.example.com --email a@example.com
      mix pesque.account list
      mix pesque.account show --handle alice.example.com
      mix pesque.account delete --handle alice.example.com
      mix pesque.account reset-password --did did:plc:...
      mix pesque.account plc-token --did did:plc:...
      mix pesque.account email-token --did did:plc:...
      mix pesque.account reset-token --did did:plc:...

  Plain inputs come from the flag, then the conventional environment, then a
  prompt. Passwords come from a no-echo prompt, or from a line on stdin so it
  can be piped: `echo secret | mix pesque.account create ...`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["account" | argv])
end
