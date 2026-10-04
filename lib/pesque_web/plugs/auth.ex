defmodule PesqueWeb.Plugs.Auth do
  @moduledoc "Requires a valid access token for an account this server hosts."

  import Plug.Conn

  require Logger

  alias Pesque.Accounts
  alias Pesque.Accounts.User

  def init(opts), do: opts

  # The account is looked up, not inferred from the token's subject. A validly
  # signed token for an account this server does not host has no one behind it,
  # so it is rejected the same way a bad signature is.
  #
  # The reason is logged because a stranger scanning, a client with a wrong
  # clock and a user whose session broke all look identical from outside, and
  # only the first two are worth knowing about. Token.verify/3 folds a bad
  # signature, a wrong scope and an expired token into one answer, so this
  # separates a missing token from a rejected one and an unknown account, and
  # no further. The token itself is never logged.
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <-
           Pesque.Token.verify(token, Pesque.Secret.get(), "com.atproto.access"),
         %User{} = user <- Accounts.get_user(claims["sub"]) do
      conn
      |> assign(:did, user.did)
      |> assign(:current_user, user)
    else
      reason ->
        Logger.warning("rejected request: #{describe(reason)}", route: conn.request_path)

        PesqueWeb.Xrpc.error(
          conn,
          401,
          "AuthenticationRequired",
          "a valid access token is required"
        )
    end
  end

  defp describe([_ | _]), do: "no bearer token"
  defp describe({:error, :invalid_token}), do: "token did not verify"
  defp describe(nil), do: "token named an account this server does not host"
  defp describe(_), do: "malformed authorization header"
end
