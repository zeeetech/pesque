defmodule PesqueWeb.Plugs.RateLimit do
  @moduledoc """
  Turns the spec's per-endpoint limits into something the router can hang on a
  pipeline.

  Two keys are counted, not one: the account the token names and the address
  the request came from. One account is one limit however many addresses it
  uses, and one address is one limit however many accounts it holds, so
  neither a single client spreading requests out nor a single client holding a
  dozen accounts gets past the number the spec chose. Both are counted in one
  pass, and the tighter of the two answers.

  Which address that is depends on what is in front of the server, and the
  README says Caddy or nginx is. `x-forwarded-for` is therefore read ahead of
  the socket, because behind a proxy every request arrives from the proxy and
  one caller could spend the whole server's budget. It is trusted on the
  operator's word that a proxy is in front; a server reachable directly, with
  the header forgeable, is a server whose per-address limit is worth nothing.
  """

  import Plug.Conn

  alias Pesque.RateLimit

  @doc """
  Options: `:bucket` names the limit class, `:limit` and `:window` size it.

  `:window` is in milliseconds and defaults to an hour, which is what the
  spec's limits are written against.
  """
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      window: Keyword.get(opts, :window, 3_600_000)
    }
  end

  def call(conn, %{bucket: bucket, limit: limit, window: window}) do
    # Counted once and then read, rather than counted per key and counted
    # again to build the headers: a passing request that incremented its
    # counter twice would spend the caller's budget at half the advertised rate.
    results = Enum.map(keys(conn, bucket), &RateLimit.hit(&1, limit, window))

    case Enum.find(results, &match?({:error, _retry}, &1)) do
      nil -> headers(conn, limit, window, spent(results))
      {:error, retry_after} -> refuse(conn, limit, window, retry_after)
    end
  end

  defp keys(conn, bucket) do
    address = {:address, bucket, address(conn)}

    case Map.get(conn.assigns, :did) do
      nil -> [address]
      did -> [{:account, bucket, did}, address]
    end
  end

  defp address(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  # Remaining is taken from whichever key is closest to its ceiling, which is
  # the one that would have refused first.
  defp spent(results) do
    results
    |> Enum.flat_map(fn
      {:ok, count} -> [count]
      {:error, _retry} -> []
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp headers(conn, limit, window, count) do
    conn
    |> put_resp_header("ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("ratelimit-remaining", Integer.to_string(max(limit - count, 0)))
    |> put_resp_header("ratelimit-reset", Integer.to_string(ceil(window / 1000)))
  end

  defp refuse(conn, limit, window, retry_after) do
    seconds = ceil(retry_after / 1000)

    conn
    |> headers(limit, window, limit)
    # Before the error is built, because Xrpc.error/4 puts a response and
    # anything set afterwards lands on a conn nobody reads.
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> PesqueWeb.Xrpc.error(
      429,
      "RateLimitExceeded",
      "too many requests; retry in #{seconds}s"
    )
  end
end
