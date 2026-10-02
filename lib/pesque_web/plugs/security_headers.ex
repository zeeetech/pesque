defmodule PesqueWeb.Plugs.SecurityHeaders do
  @moduledoc "Baseline hardening headers on every response."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("strict-transport-security", "max-age=63072000; includeSubDomains")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    )
  end
end
