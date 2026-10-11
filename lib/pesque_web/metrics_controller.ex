defmodule PesqueWeb.MetricsController do
  @moduledoc """
  GET /metrics: the Prometheus exposition of `Pesque.Metrics.snapshot/0`.

  Off by default, and the off state is a 404 rather than a 401: a server
  that answers the metrics route at all has told a stranger there is
  something here worth measuring. A non-empty `metrics_token` turns it on,
  and the token is then the whole gate, compared in constant time like every
  other pair of secrets this server puts side by side.

  It runs behind the read budget like every other GET, so a scrape flood is
  refused by the rate limiter before it costs a snapshot. The endpoint is
  for the operator's own collector and is not published by Caddy: the
  monitoring stack reaches it over the compose network, and anything further
  away over an SSH tunnel. See "Metrics and monitoring" in
  docs/guides/operations.md.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  def show(conn, _params) do
    case Application.get_env(:pesque, :metrics_token, "") do
      # Off means not there, which is the answer a path with no route gets.
      "" ->
        send_resp(conn, 404, "")

      token ->
        if authorized?(conn, token) do
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, Pesque.Metrics.Format.render(Pesque.Metrics.snapshot()))
        else
          send_resp(conn, 401, "")
        end
    end
  end

  # The length check runs first because secure_compare on two strings of
  # different lengths answers false before the loop, and equal lengths make
  # the whole comparison run, which is what a secret comparison owes a
  # guesser. Same shape as the token check in Plugs.Auth.
  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] ->
        byte_size(presented) == byte_size(token) and Plug.Crypto.secure_compare(presented, token)

      _ ->
        false
    end
  end
end
