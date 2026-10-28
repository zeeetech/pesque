defmodule Pesque.Cli.Crawl do
  @moduledoc """
  Asks every configured relay to crawl this server: the announcement a boot
  makes, on demand.
  """

  alias Pesque.Cli.Input
  alias Pesque.Cli.Runtime

  @usage "usage: pesque crawl request"

  def run(["--help"]), do: {:help, @usage}

  def run(["request" | argv]) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Runtime.start() do
      if Pesque.crawlers() == [] do
        {:error, :no_crawler_configured}
      else
        Pesque.Crawl.request_all()
        Enum.each(Pesque.crawlers(), &IO.puts("asked #{&1} to crawl this server"))
        :ok
      end
    end
  end

  def run(_argv), do: {:usage, @usage}
end
