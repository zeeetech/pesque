defmodule Mix.Tasks.Pesque.CreateAccount do
  @shortdoc "Provisions a local account (pesque.account create)"

  @moduledoc """
  The old name of `mix pesque.account create`, kept so existing guides and
  scripts keep working.

      mix pesque.create_account --handle alice.example.com --email a@example.com --password-env PESQUE_PASSWORD

  Creates an account through Pesque.Accounts.create_account/3, the same
  function the HTTP endpoint calls, so there is one code path that creates an
  account rather than two that can drift.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["account", "create" | argv])
end
