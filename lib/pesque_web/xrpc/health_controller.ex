defmodule PesqueWeb.Xrpc.HealthController do
  use Phoenix.Controller, formats: [:json]

  def show(conn, _params) do
    json(conn, %{"status" => "ok", "version" => Pesque.version()})
  end
end
