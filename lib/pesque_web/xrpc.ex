defmodule PesqueWeb.Xrpc do
  @moduledoc "Helpers for the XRPC error contract."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias PesqueWeb.Xrpc.Errors

  @doc "Answers a domain reason as the XRPC error Errors.to_xrpc/1 decides it is."
  def error(conn, reason) do
    {status, name, message} = Errors.to_xrpc(reason)
    error(conn, status, name, message)
  end

  def error(conn, status, name, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => name, "message" => message})
    |> halt()
  end
end
