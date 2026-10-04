defmodule PesqueWeb.Plugs.Auth do
  @moduledoc "Requires a valid access token for an account this server hosts."

  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Accounts.User

  def init(opts), do: opts

  # The account is looked up, not inferred from the token's subject. A validly
  # signed token for an account this server does not host has no one behind it,
  # so it is rejected the same way a bad signature is.
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <-
           Pesque.Token.verify(token, Pesque.Secret.get(), "com.atproto.access"),
         %User{} = user <- Accounts.get_user(claims["sub"]) do
      conn
      |> assign(:did, user.did)
      |> assign(:current_user, user)
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
