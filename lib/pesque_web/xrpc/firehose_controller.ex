defmodule PesqueWeb.Xrpc.FirehoseController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias PesqueWeb.Xrpc.Params

  def upgrade(conn, _params) do
    cursor =
      case conn.params["cursor"] do
        nil ->
          nil

        value ->
          case Params.int(value) do
            n when is_integer(n) and n >= 0 ->
              n

            _ ->
              # Not "treat it like no cursor": silently replaying from live
              # hides a client bug that the caller deserves to hear about.
              Logger.warning("firehose: dropping unparsable cursor #{inspect(value)}")
              :invalid
          end
      end

    WebSockAdapter.upgrade(conn, PesqueWeb.Firehose, %{cursor: cursor}, [])
  end
end
