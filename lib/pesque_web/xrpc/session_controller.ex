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
      "links" => links()
    })
  end

  # Absolute URLs to the documents this server serves itself, because a client
  # reading describeServer from another host cannot follow a path.
  defp links do
    base = Pesque.base_url()

    %{
      "privacyPolicy" => base <> "/privacy-policy.md",
      "termsOfService" => base <> "/terms-of-service.md"
    }
  end

  # What an AppView asks before it mirrors a repo. `activated` is answered from
  # the row and not from the token, so a deleted account reads as deactivated
  # to a caller holding a session it has not noticed is dead yet.
  def check_account_status(conn, %{"did" => did}) do
    case Accounts.repo_did(did) do
      {:ok, resolved} ->
        json(conn, account_status(resolved))

      {:error, _reason} ->
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

  # Open registration needs nothing from the caller. Closed registration is
  # invite-only, which is what describeServer already advertises: a code the
  # operator handed out, spent exactly once.
  def create_account(conn, params) do
    case invite_code(params) do
      {:ok, opts} -> provision(conn, params, opts)
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp invite_code(params) do
    case Pesque.registration() do
      :open ->
        {:ok, []}

      :closed ->
        case params["invitationCode"] do
          code when is_binary(code) -> {:ok, [invite_code: code]}
          _ -> {:error, :invite_code_required}
        end
    end
  end

  defp provision(conn, params, opts) do
    case Accounts.create_account(params["handle"], params["email"], params["password"], opts) do
      {:ok, user} ->
        {:ok, session} = Accounts.issue_session(user.did)

        json(conn, %{
          "accessJwt" => session.access_jwt,
          "refreshJwt" => session.refresh_jwt,
          "handle" => user.handle,
          "did" => user.did,
          "active" => true
        })

      {:error, reason} ->
        fail(conn, reason)
    end
  end

  defp fail(conn, reason) do
    {status, name, message} = Xrpc.Errors.to_xrpc(reason)
    Xrpc.error(conn, status, name, message)
  end

  def create_session(conn, %{"identifier" => identifier, "password" => password}) do
    case Accounts.verify_login(identifier, password) do
      {:ok, user} ->
        {:ok, session} = Accounts.issue_session(user.did)

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
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
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
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         :ok <- Accounts.revoke_session(token) do
      json(conn, %{})
    else
      _ -> Xrpc.error(conn, 401, "InvalidToken", "refresh token is expired or revoked")
    end
  end

  def create_invite_codes(conn, params) do
    case Accounts.create_invite_code(code_count(params)) do
      {:ok, codes} -> json(conn, %{"codes" => codes})
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp code_count(%{"codeCount" => count}) when is_integer(count), do: count
  defp code_count(_params), do: 1

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
