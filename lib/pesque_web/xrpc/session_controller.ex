defmodule PesqueWeb.Xrpc.SessionController do
  @moduledoc "com.atproto.server.* session endpoints: account creation, login, rotation, logout."

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts

  def create_account(conn, params) do
    if Pesque.registration() == :open do
      provision(conn, params)
    else
      PesqueWeb.Xrpc.error(
        conn,
        400,
        "InvalidRequest",
        "registration is closed; accounts are provisioned by the operator"
      )
    end
  end

  defp provision(conn, params) do
    case Accounts.create_account(params["handle"], params["email"], params["password"]) do
      {:ok, user} ->
        session = Accounts.issue_session(user.did)

        json(conn, %{
          "accessJwt" => session.access_jwt,
          "refreshJwt" => session.refresh_jwt,
          "handle" => user.handle,
          "did" => user.did,
          "active" => true
        })

      {:error, :account_exists} ->
        PesqueWeb.Xrpc.error(conn, 400, "AccountExists", "this server already hosts its account")

      {:error, :handle_not_available} ->
        PesqueWeb.Xrpc.error(
          conn,
          400,
          "HandleNotAvailable",
          "handle is not available on this server"
        )

      {:error, :password_too_short} ->
        PesqueWeb.Xrpc.error(
          conn,
          400,
          "InvalidRequest",
          "password must be at least 8 characters"
        )

      {:error, :email_required} ->
        PesqueWeb.Xrpc.error(conn, 400, "InvalidRequest", "an email is required")

      {:error, :email_taken} ->
        PesqueWeb.Xrpc.error(
          conn,
          400,
          "InvalidRequest",
          "email is already used as a handle on this server"
        )

      {:error, _reason} ->
        PesqueWeb.Xrpc.error(conn, 400, "InvalidRequest", "account could not be created")
    end
  end

  def create_session(conn, %{"identifier" => identifier, "password" => password}) do
    case Accounts.verify_login(identifier, password) do
      {:ok, user} ->
        session = Accounts.issue_session(user.did)

        json(conn, %{
          "accessJwt" => session.access_jwt,
          "refreshJwt" => session.refresh_jwt,
          "handle" => user.handle,
          "did" => user.did,
          "email" => user.email,
          "active" => true
        })

      :error ->
        PesqueWeb.Xrpc.error(
          conn,
          401,
          "AuthenticationRequired",
          "invalid identifier or password"
        )
    end
  end

  def create_session(conn, _params) do
    PesqueWeb.Xrpc.error(conn, 400, "InvalidRequest", "identifier and password are required")
  end

  # The refresh token's subject names the account, so the answer is that
  # account's and nobody else's. rotate_session/1 refuses a token whose
  # subject is not an account, so a live token cannot outlive its account.
  def refresh_session(conn, _params) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, session, user} <- Accounts.rotate_session(token) do
      json(conn, %{
        "accessJwt" => session.access_jwt,
        "refreshJwt" => session.refresh_jwt,
        "handle" => user.handle,
        "did" => user.did,
        "active" => true
      })
    else
      _ -> PesqueWeb.Xrpc.error(conn, 401, "InvalidToken", "refresh token is expired or revoked")
    end
  end

  def delete_session(conn, _params) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         :ok <- Accounts.revoke_session(token) do
      json(conn, %{})
    else
      _ -> PesqueWeb.Xrpc.error(conn, 401, "InvalidToken", "refresh token is expired or revoked")
    end
  end

  def get_session(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      "handle" => user.handle,
      "did" => user.did,
      "email" => user.email,
      "active" => true
    })
  end
end
