defmodule PesqueWeb.Xrpc.ProxyController do
  @moduledoc """
  The catch-all for XRPC methods this server does not implement.

  A call naming a target with `atproto-proxy` is forwarded to that service; a
  call naming none is `501 MethodNotImplemented`, exactly as a server with no
  default AppView should answer. The upstream's own status is passed through,
  so a 404, 403 or 429 from the target reaches the client as one.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Entryway
  alias Pesque.Entryway.{Call, Response}
  alias PesqueWeb.Xrpc

  # The upstream headers worth carrying back. Anything else (content-length,
  # set-cookie, hop-by-hop headers) is either recomputed by the connection or
  # not the target's to set on this server's response.
  @forwarded_headers ~w(content-type content-encoding cache-control www-authenticate)

  def forward(conn, _params) do
    call = call(conn)

    case call do
      %Call{method: :unsupported} ->
        Xrpc.error(conn, 400, "InvalidRequest", "XRPC uses GET or POST")

      %Call{} ->
        case Entryway.forward(call, conn.assigns.did) do
          {:ok, %Response{} = response} -> respond(conn, response)
          {:error, reason} -> Xrpc.error(conn, reason)
        end
    end
  end

  defp call(conn) do
    %Call{
      method: method(conn.method),
      nsid: String.replace_prefix(conn.request_path, "/xrpc/", ""),
      proxy: List.first(get_req_header(conn, "atproto-proxy")),
      query: conn.query_string,
      body: body(conn),
      headers: conn.req_headers
    }
  end

  defp method("GET"), do: :get
  defp method("POST"), do: :post
  defp method(_other), do: :unsupported

  # The body is re-encoded from the parsed params rather than forwarded byte
  # for byte: the parser already consumed it, and the target accepts JSON.
  defp body(%{method: "POST"} = conn) do
    if json?(conn), do: JSON.encode!(conn.body_params), else: nil
  end

  defp body(_conn), do: nil

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [value | _] -> String.contains?(value, "json")
      [] -> false
    end
  end

  defp respond(conn, %Response{status: status, headers: headers, body: body}) do
    conn
    |> put_forwarded(headers)
    |> send_resp(status, body)
  end

  defp put_forwarded(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      if String.downcase(name) in @forwarded_headers,
        do: put_resp_header(acc, String.downcase(name), value),
        else: acc
    end)
  end
end
