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
  alias Pesque.ServiceAuth
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
  # rest follows from it. `activated` is the account's own state, so a
  # deactivated repo answers false here and in sync.getRepoStatus rather than
  # one saying active and the other not.
  defp account_status(did) do
    active = Accounts.repo_active?(did)

    %{
      "activated" => active,
      "validDid" => true,
      "repoCommit" => RepoStore.get_meta("commit:" <> did),
      "repoRev" => RepoStore.get_meta("rev:" <> did),
      "repoBlocks" => RepoStore.block_count(did),
      "indexable" => active,
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
        case params["inviteCode"] do
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
    case Accounts.create_invite_codes(code_count(params), use_count(params), for_accounts(params)) do
      {:ok, groups} -> json(conn, %{"codes" => Enum.map(groups, &group/1)})
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp group(%{account: account, codes: codes}),
    do: %{"account" => account, "codes" => codes}

  defp code_count(%{"codeCount" => count}), do: count
  defp code_count(_params), do: 1

  defp use_count(%{"useCount" => count}), do: count
  defp use_count(_params), do: nil

  defp for_accounts(%{"forAccounts" => [did | _] = dids}) when is_binary(did), do: dids
  defp for_accounts(_params), do: []

  # The lexicon has this token delivered by email and answers an empty object.
  # There is no mail here, so it is answered in the body: a token that was
  # recorded and never delivered would make the account undeletable.
  def request_account_delete(conn, _params) do
    case Accounts.request_account_delete(conn.assigns.current_user) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        json(conn, %{"token" => token, "expiresAt" => DateTime.to_iso8601(expires_at)})

      {:error, reason} ->
        fail(conn, reason)
    end
  end

  def delete_account(conn, %{"did" => did, "password" => password, "token" => token}) do
    case Accounts.delete_account(conn.assigns.current_user, did, password, token) do
      {:ok, _did} -> json(conn, %{})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def delete_account(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did, password and token are required")
  end

  # Deactivation stops writes and announces itself; the repo itself stays, so
  # activateAccount can bring it back and a mirror can still ask what happened.
  #
  # deleteAfter is a recommendation about how long to hold the account, and
  # nothing here acts on it. Scheduling a deletion from it would be a second
  # way to destroy an account, next to the two-step flow deleteAccount already
  # is, and the wrong one to get wrong.
  def deactivate_account(conn, _params) do
    case Accounts.deactivate_account(conn.assigns.current_user) do
      {:ok, _did} -> json(conn, %{})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def activate_account(conn, _params) do
    case Accounts.activate_account(conn.assigns.current_user) do
      {:ok, _did} -> json(conn, %{})
      {:error, reason} -> fail(conn, reason)
    end
  end

  # A token for another service to accept, proving this account to it. The
  # account is the authenticated one and its key does the signing, so the
  # token says nothing the account's DID document does not already say.
  #
  # The token itself is never logged, and neither is the failure: a rejected
  # audience is a caller mistake and the reason is already in the body.
  def get_service_auth(conn, params) do
    case ServiceAuth.mint(conn.assigns.did, params["aud"], opts(params)) do
      {:ok, token} -> json(conn, %{"token" => token})
      {:error, reason} -> fail(conn, reason)
    end
  end

  # exp is an integer in the lexicon and arrives as query-string text. Only a
  # string that is entirely digits becomes one; anything else is passed through
  # untouched so ServiceAuth answers BadExpiration for it rather than this
  # module deciding what a number is.
  defp opts(params) do
    [exp: parse_exp(params["exp"]), lxm: params["lxm"]]
  end

  defp parse_exp(nil), do: nil

  defp parse_exp(exp) when is_binary(exp) do
    case Integer.parse(exp) do
      {n, ""} -> n
      _other -> exp
    end
  end

  defp parse_exp(exp), do: exp

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
