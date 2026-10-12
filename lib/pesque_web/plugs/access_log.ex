defmodule PesqueWeb.Plugs.AccessLog do
  @moduledoc """
  One structured line per response: what was asked, what it answered, and who
  asked.

  This replaces `Plug.Logger`. A line carrying only a method, a path and a
  status cannot answer the operator's actual question - who is hitting this
  server - and a failure that carries no body cannot say what went wrong
  without a redeploy to add logging. So every response gets a `requester`, and
  a response at 400 or above also gets the body it answered with.

  The requester is what makes a log filterable. An authorization request from a
  client, an indexer's backfill reads and an app's record reads arrive as
  different identities: only the first carries a `client_id`, only some carry
  an account DID, and for the rest the user agent is the only name there is,
  which is exactly what a crawler has. When both a client and an account are
  present the client wins, because the question being asked is which
  application is speaking, not which account it acts for.

  The body is the response, never the request: a request can carry a password,
  and this logs no credential. It is capped so one HTML error page cannot bury
  the line, and collapsed to a single line so a multi-line body stays greppable.

  `x-forwarded-for` is read ahead of the socket, the same rule `RateLimit`
  uses: behind the proxy the socket address is the proxy for every caller.
  """

  import Plug.Conn

  require Logger

  @body_limit 2_048

  def init(opts), do: opts

  def call(conn, _opts) do
    started = System.monotonic_time()
    register_before_send(conn, &log(&1, started))
  end

  defp log(conn, started) do
    micros = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

    Logger.log(
      level(conn.status),
      "#{conn.method} #{conn.request_path} #{conn.status} in #{duration(micros)}",
      metadata(conn)
    )

    conn
  end

  defp level(status) when is_integer(status) and status >= 500, do: :error
  defp level(status) when is_integer(status) and status >= 400, do: :warning
  defp level(_status), do: :info

  defp metadata(conn) do
    base = [
      requester: requester(conn),
      user_agent: user_agent(conn),
      remote_ip: address(conn)
    ]

    if is_integer(conn.status) and conn.status >= 400 do
      base ++ [body: body(conn)]
    else
      base
    end
  end

  defp requester(conn) do
    cond do
      is_binary(client_id(conn)) -> host_of(client_id(conn))
      is_binary(conn.assigns[:did]) -> conn.assigns[:did]
      is_binary(user_agent(conn)) -> user_agent(conn)
      true -> "unknown"
    end
  end

  defp client_id(conn), do: conn.assigns[:client_id] || param(conn, "client_id")

  defp param(conn, key) do
    if is_map(conn.params), do: Map.get(conn.params, key)
  end

  defp host_of(client_id) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) -> host
      _other -> client_id
    end
  end

  defp user_agent(conn), do: List.first(get_req_header(conn, "user-agent"))

  defp address(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _rest] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp body(conn) do
    case conn.resp_body do
      body when is_binary(body) -> one_line(body)
      body when is_list(body) -> one_line(IO.iodata_to_binary(body))
      _other -> ""
    end
  end

  defp one_line(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
  end

  defp truncate(body) when byte_size(body) <= @body_limit, do: body
  defp truncate(body), do: String.slice(body, 0, @body_limit) <> "..."

  # The same three brackets Plug.Logger used, so a reader of the old lines is
  # not made to relearn them.
  defp duration(micros) when micros < 1_000, do: "#{micros}µs"
  defp duration(micros) when micros < 1_000_000, do: "#{div(micros, 1_000)}ms"
  defp duration(micros), do: "#{div(micros, 1_000_000)}s"
end
