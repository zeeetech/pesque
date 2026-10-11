defmodule Pesque.Cli.Crawl do
  @moduledoc """
  Asks every configured relay to crawl this server: the announcement a boot
  makes, on demand.
  """

  alias Pesque.Cli.Input
  alias Pesque.Release

  @usage "usage: pesque crawl request"

  def run(["request" | argv]) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Release.boot!(),
         true <- Pesque.crawlers() != [] do
      Pesque.Crawl.request_all()
      Enum.each(Pesque.crawlers(), &IO.puts("asked #{&1} to crawl this server"))
      :ok
    else
      false -> {:error, :no_crawler_configured}
      other -> other
    end
  end

  def run(_argv), do: {:usage, @usage}
end
