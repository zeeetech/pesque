defmodule PesqueWeb.Xrpc.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def not_implemented(conn, _params) do
    conn
    |> put_status(501)
    |> json(%{"error" => "MethodNotImplemented", "message" => "unknown XRPC method"})
  end
end
