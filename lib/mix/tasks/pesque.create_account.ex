defmodule Mix.Tasks.Pesque.CreateAccount do
  @shortdoc "Provisions a local account (pesque.account create)"

  @moduledoc """
  The old name of `mix pesque.account create`, kept so existing guides and
  scripts keep working.

      mix pesque.create_account --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD

  Creates an account through Pesque.Accounts.create_account/3, the same
  function the HTTP endpoint calls, so there is one code path that creates an
  account rather than two that can drift.

  Password precedence: `--password VALUE` wins over `--password-env NAME`,
  which wins over a no-echo prompt. The flag is dev convenience for throwaway
  local accounts - the value lands in your shell history and in `ps` - and
  it never reaches the verb layer: this task sets it as the environment
  variable the verb reads and dispatches an argv with no password in it.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv),
    do: Mix.Pesque.run_with_password(["account", "create" | argv], "ACCOUNT_PASSWORD")
end
