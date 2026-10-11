defmodule Pesque.Cli.Health do
  @moduledoc """
  The data-directory half of health: opens the server's world with the
  endpoint down and asks its database a question. The driver's health()
  checks the live server from outside; this checks that the data directory a
  one-off opened can serve.
  """

  alias Pesque.Cli.Input
  alias Pesque.Release
  alias Pesque.RepoStore

  @usage "usage: pesque health"

  def run(argv) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Release.boot!(),
         :ok <- RepoStore.health_check() do
      IO.puts("the database answers; the data directory is open")
      :ok
    end
  end
end
