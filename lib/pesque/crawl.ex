defmodule Pesque.Crawl do
  @moduledoc """
  Tells a relay this server exists, so the relay starts crawling its repos.

  `com.atproto.sync.requestCrawl` is a method a **relay** implements and a PDS
  calls; there is no server side to it here. It runs once at boot, in a task,
  because a relay that is slow or down must not hold up or fail this server's
  start. Relays also discover PDS instances by other means, so an operator who
  configures no crawler loses nothing else.
  """

  require Logger

  alias Pesque.OAuth.Fetch

  @doc "Asks every configured crawler to crawl this server. Never raises."
  def request_all do
    Enum.each(Pesque.crawlers(), &request/1)
  end

  defp request(base) do
    url = String.trim_trailing(base, "/") <> "/xrpc/com.atproto.sync.requestCrawl"

    with {:ok, uri} <- URI.new(url),
         :ok <- Fetch.post_json(uri, %{"hostname" => Pesque.hostname()}) do
      Logger.info("asked a relay to crawl this server", crawler: base)
    else
      {:error, reason} ->
        Logger.warning("a relay could not be reached", crawler: base, reason: inspect(reason))
    end

    :ok
  end
end
