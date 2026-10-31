defmodule Mix.Tasks.Pesque.Prepare do
  use Mix.Task

  @shortdoc "Prepares storage, keys and the database"

  @requirements ["app.config"]

  @impl true
  def run([]) do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    Pesque.Release.prepare()
  end

  def run(_args) do
    Mix.raise("usage: mix pesque.prepare")
  end
end
