defmodule PesqueWeb.Xrpc.FirehoseController do
  use Phoenix.Controller, formats: [:json]

  def upgrade(conn, _params) do
    cursor =
      case conn.params["cursor"] do
        nil ->
          nil

        value ->
          case Integer.parse(value) do
            {n, ""} when n >= 0 -> n
            _ -> nil
          end
      end

    WebSockAdapter.upgrade(conn, PesqueWeb.Firehose, %{cursor: cursor}, [])
  end
end
