defmodule PesqueWeb.Plugs.Auth do
  @moduledoc "Requires a valid access token; assigns the authenticated DID."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <-
           Pesque.Token.verify(token, Pesque.Secret.get(), "com.atproto.access") do
      assign(conn, :did, claims["sub"])
    else
      _ ->
        PesqueWeb.Xrpc.error(
          conn,
          401,
          "AuthenticationRequired",
          "a valid access token is required"
        )
    end
  end
end
