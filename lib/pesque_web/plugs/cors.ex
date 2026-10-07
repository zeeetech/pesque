defmodule PesqueWeb.Plugs.Cors do
  @moduledoc """
  Permissive CORS. Repositories are public data and browser clients are
  hosted on other origins; bearer tokens, not cookies, carry authority.

  The allowed request headers are echoed from the preflight's
  `access-control-request-headers` rather than fixed here. Clients send headers
  this server does not know about (`x-atproto-bsky-topics` is one the official
  app sends), and a fixed list turns each new one into a CORS failure. A
  request without that header is not a preflight and gets the static fallback.
  """

  import Plug.Conn

  @fallback_headers "authorization, content-type, atproto-proxy, atproto-accept-labelers"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts), do: put_cors_headers(conn)

  defp put_cors_headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", allow_headers(conn))
    |> put_resp_header("access-control-max-age", "86400")
    # vary: origin even though the origin is always "*": caches must not serve
    # a response that priced in one origin to a request bearing another. The
    # allowed headers are echoed per request too, so a cache has to key on the
    # header that decided them as well.
    |> put_resp_header("vary", "origin, access-control-request-headers")
  end

  # The browser names the headers it wants to send; echoing them is what the
  # reference PDS does (express `cors` with no allowedHeaders), and it keeps a
  # client's new header from being a CORS failure. Without the header there is
  # nothing to echo, so a static set that covers the ordinary client stands in.
  defp allow_headers(conn) do
    case get_req_header(conn, "access-control-request-headers") do
      [headers | _] -> headers
      [] -> @fallback_headers
    end
  end
end
