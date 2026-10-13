defmodule Mix.Tasks.Pesque.CreateAccount do
  @shortdoc "Provisions a local account (pesque.account create)"

  @moduledoc """
  The old name of `mix pesque.account create`, kept so existing guides and
  scripts keep working.

      mix pesque.create_account --handle alice.example.com --email a@example.com

  The password is read from a no-echo prompt, or from a line on stdin so it
  can be piped: `echo secret | mix pesque.create_account ...`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["account", "create" | argv])
end
