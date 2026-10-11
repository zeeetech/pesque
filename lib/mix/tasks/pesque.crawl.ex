defmodule Mix.Tasks.Pesque.Crawl do
  @shortdoc "Asks the configured relays to crawl this server"

  @moduledoc """
  Asks every configured relay to crawl this server: the announcement a boot
  makes, on demand.

      mix pesque.crawl request
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["crawl" | argv])
end
