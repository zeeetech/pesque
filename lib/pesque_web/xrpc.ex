defmodule PesqueWeb.Xrpc do
  @moduledoc "Helpers for the XRPC error contract."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def error(conn, status, name, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => name, "message" => message})
    |> halt()
  end
end
