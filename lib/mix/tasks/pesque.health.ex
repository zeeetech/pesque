defmodule Mix.Tasks.Pesque.Health do
  @shortdoc "Checks that the data directory can serve"

  @moduledoc """
  Opens the server's world with the endpoint down and asks its database a
  question, the same check `bin/pesque health` runs. The driver's health
  checks the live server from outside; this checks that the data directory a
  one-off opened can serve.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["health" | argv])
end
