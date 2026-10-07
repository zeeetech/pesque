defmodule PesqueWeb.Plugs.Cors do
  @moduledoc """
  Permissive CORS. Repositories are public data and browser clients are
  hosted on other origins; bearer tokens, not cookies, carry authority.
  """

  import Plug.Conn

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
    |> put_resp_header(
      "access-control-allow-headers",
      "authorization, content-type, atproto-proxy, atproto-accept-labelers"
    )
    |> put_resp_header("access-control-max-age", "86400")
    # vary: origin even though the origin is always "*": caches must not serve
    # a response that priced in one origin to a request bearing another.
    |> put_resp_header("vary", "origin")
  end
end
