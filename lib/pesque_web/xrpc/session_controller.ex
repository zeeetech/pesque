defmodule PesqueWeb.Xrpc.SessionController do
  @moduledoc """
  com.atproto.server.*: what this server is, and the session endpoints.

  describeServer and checkAccountStatus are here rather than in a controller
  of their own because the spec puts them in the same namespace and neither
  needs anything the session endpoints do not already have.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts
  alias Pesque.Identity
  alias Pesque.RepoStore
  alias PesqueWeb.Xrpc

  # The first thing every client asks. A server that does not answer it cannot
  # be used by an app that follows the spec, whatever else it implements, so it
  # is deliberately the smallest answer in this controller.
  def describe_server(conn, _params) do
    json(conn, %{
      "did" => Identity.did(),
      "availableUserDomains" => [Pesque.handle_domain()],
      "inviteCodeRequired" => Pesque.registration() == :closed,
      "phoneVerificationRequired" => false,
      "links" => %{}
    })
  end

  # What an AppView asks before it mirrors a repo. `activated` is answered from
  # the row and not from the token, so a deleted account reads as deactivated
  # to a caller holding a session it has not noticed is dead yet.
  def check_account_status(conn, %{"did" => did}) do
    case Accounts.repo_did(did) do
      {:ok, resolved} ->
        json(conn, account_status(resolved))

      :error ->
        json(conn, %{
          "activated" => false,
          "validDid" => true,
          "repoCommit" => nil,
          "repoRev" => nil,
          "repoBlocks" => 0,
          "indexable" => false,
          "cdns" => [],
          "blobDiverged" => false
        })
    end
  end

  def check_account_status(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end

  # A repo with no commit is a repo nobody has written to, which is not the
  # same as a repo that is not there. `repoCommit` is null in that case and the
  # rest follows from it.
  defp account_status(did) do
    %{
      "activated" => true,
      "validDid" => true,
      "repoCommit" => RepoStore.get_meta("commit:" <> did),
      "repoRev" => RepoStore.get_meta("rev:" <> did),
      "repoBlocks" => RepoStore.block_count(did),
      "indexable" => true,
      "cdns" => [],
      "blobDiverged" => false
    }
  end

  def create_account(conn, params) do
    if Pesque.registration() == :open do
      provision(conn, params)
    else
      Xrpc.error(
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
        Xrpc.error(conn, 400, "AccountExists", "this server already hosts its account")

      {:error, :handle_not_available} ->
        Xrpc.error(
          conn,
          400,
          "HandleNotAvailable",
          "handle is not available on this server"
        )

      {:error, :password_too_short} ->
        Xrpc.error(
          conn,
          400,
          "InvalidRequest",
          "password must be at least 8 characters"
        )

      {:error, :email_required} ->
        Xrpc.error(conn, 400, "InvalidRequest", "an email is required")

      {:error, :email_taken} ->
        Xrpc.error(
          conn,
          400,
          "InvalidRequest",
          "email is already used as a handle on this server"
        )

      {:error, _reason} ->
        Xrpc.error(conn, 400, "InvalidRequest", "account could not be created")
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
        Xrpc.error(
          conn,
          401,
          "AuthenticationRequired",
          "invalid identifier or password"
        )
    end
  end

  def create_session(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "identifier and password are required")
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
      _ -> Xrpc.error(conn, 401, "InvalidToken", "refresh token is expired or revoked")
    end
  end

  def delete_session(conn, _params) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         :ok <- Accounts.revoke_session(token) do
      json(conn, %{})
    else
      _ -> Xrpc.error(conn, 401, "InvalidToken", "refresh token is expired or revoked")
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
