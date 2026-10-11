defmodule Mix.Tasks.Pesque.CreateAccount do
  @shortdoc "Provisions a local account (pesque.account create)"

  @moduledoc """
  The old name of `mix pesque.account create`, kept so existing guides and
  scripts keep working.

      mix pesque.create_account --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD

  `--password VALUE` is a dev convenience for throwaway local accounts (the
  value lands in your shell history and in `ps`): the task sets it as the
  environment variable the verb reads and dispatches an argv with no
  password in it.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv),
    do: Mix.Pesque.run_with_password(["account", "create" | argv], "ACCOUNT_PASSWORD")
end
