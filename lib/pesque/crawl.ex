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

  @timeout 10_000

  @doc "Asks every configured crawler to crawl this server. Never raises."
  def request_all do
    Enum.each(Pesque.crawlers(), &request/1)
  end

  def request(base) do
    url = String.trim_trailing(base, "/") <> "/xrpc/com.atproto.sync.requestCrawl"
    body = JSON.encode!(%{"hostname" => Pesque.hostname()})

    case :httpc.request(
           :post,
           {String.to_charlist(url), [{~c"content-type", ~c"application/json"}],
            ~c"application/json", body},
           [timeout: @timeout, connect_timeout: @timeout],
           []
         ) do
      {:ok, {{_v, status, _r}, _headers, _body}} when status in 200..299 ->
        Logger.info("asked a relay to crawl this server", crawler: base, status: status)

      {:ok, {{_v, status, _r}, _headers, _body}} ->
        Logger.warning("a relay refused the crawl request", crawler: base, status: status)

      {:error, reason} ->
        Logger.warning("a relay could not be reached", crawler: base, reason: inspect(reason))
    end

    :ok
  end
end
