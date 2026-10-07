defmodule Pesque.OAuth do
  @moduledoc """
  The ATProto OAuth authorization server: PAR, authorize, token, revoke.

  Four pieces of state, in the order a client meets them:

    * A pushed authorization request. The client POSTs the whole request here
      and gets a `request_uri` back. Everything about the request is validated
      now, against the client's own published metadata, so the authorize
      endpoint has nothing left to decide and only has to ask a human.
    * The request itself, which survives the redirect to the login page. It
      carries the DPoP key it was pushed with, so the key a session is bound to
      is decided before anybody logs in.
    * A code: single use, short lived, minted once an account is approved.
    * A session: an access token and a refresh token that replaces it, both
      revocable, both recorded here hashed.

  Four things are load-bearing and are written as they are:

    * The authorize endpoint takes only `client_id` and `request_uri`. A
      request arriving any other way is refused rather than honoured, which is
      what `require_pushed_authorization_requests` in the metadata means.
    * A code is spent by a conditional update, so two exchanges of one code
      produce one session and one failure.
    * A refresh token is spent the same way, and rotating it issues a new one
      under the same session id. Replaying a spent refresh token is treated as
      compromise and revokes the session.
    * The DPoP key a request was pushed with has to be the key the token
      request presents, so a proof captured from one client cannot be carried
      against another's pushed request.

  Nothing here logs a code, a token, a DPoP proof or a password, and none of
  them reaches the database in the clear.
  """

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.OAuth.Client
  alias Pesque.OAuth.Jwt
  alias Pesque.OAuth.Keys
  alias Pesque.OAuth.Request
  alias Pesque.OAuth.Scopes
  alias Pesque.OAuth.Token
  alias Pesque.Repo

  @request_uri_prefix "urn:ietf:params:oauth:request_uri:"
  @par_ttl_seconds 300
  @code_ttl_seconds 60
  @access_ttl_seconds 900
  @refresh_ttl_seconds 14 * 24 * 60 * 60

  @doc "Seconds a pushed request stays usable."
  def par_ttl_seconds, do: @par_ttl_seconds

  @doc "Seconds an access token is valid. Under the 30 minutes the spec caps."
  def access_ttl_seconds, do: @access_ttl_seconds

  @doc "The AS metadata document, served at the well-known path."
  def metadata do
    issuer = Pesque.base_url()

    %{
      "issuer" => issuer,
      "authorization_endpoint" => issuer <> "/oauth/authorize",
      "token_endpoint" => issuer <> "/oauth/token",
      "revocation_endpoint" => issuer <> "/oauth/revoke",
      "pushed_authorization_request_endpoint" => issuer <> "/oauth/par",
      "jwks_uri" => issuer <> "/oauth/jwks.json",
      "response_types_supported" => ["code"],
      "response_modes_supported" => ["query"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
      "token_endpoint_auth_signing_alg_values_supported" => ["ES256"],
      "scopes_supported" => Scopes.supported(),
      "subject_types_supported" => ["public"],
      "dpop_signing_alg_values_supported" => ["ES256"],
      "authorization_response_iss_parameter_supported" => true,
      "require_pushed_authorization_requests" => true,
      "require_request_uri_registration" => true,
      "client_id_metadata_document_supported" => true
    }
  end

  @doc "The resource server metadata document, which points at this AS."
  def resource_metadata do
    %{
      "resource" => Pesque.base_url(),
      "authorization_servers" => [Pesque.base_url()],
      "bearer_methods_supported" => ["DPoP"],
      "scopes_supported" => Scopes.supported()
    }
  end

  @doc """
  Validates and stores a pushed authorization request.

  The DPoP proof has already been checked by the caller; `jkt` is what it
  produced. Answers {:ok, %{request_uri:, expires_in:}} or {:error, reason}.
  """
  def push_request(params, jkt) do
    with {:ok, client_id} <- required(params, "client_id"),
         {:ok, metadata} <- Client.resolve(client_id),
         :ok <- check_response_type(params),
         :ok <- check_pkce(params),
         :ok <- check_state(params),
         {:ok, redirect_uri} <- required(params, "redirect_uri"),
         :ok <- check_redirect_uri(metadata, redirect_uri),
         {:ok, scope} <- Scopes.validate(params["scope"]),
         :ok <- check_declared_scope(metadata, scope),
         :ok <- check_login_hint(params["login_hint"]),
         {:ok, request_uri} <- store_request(params, client_id, redirect_uri, scope, jkt) do
      {:ok, %{request_uri: request_uri, expires_in: @par_ttl_seconds}}
    end
  end

  defp store_request(params, client_id, redirect_uri, scope, jkt) do
    request_uri = @request_uri_prefix <> random(16)

    attrs = %{
      request_uri_hash: Request.hash(request_uri),
      client_id: client_id,
      redirect_uri: redirect_uri,
      state: params["state"],
      scope: scope,
      code_challenge: params["code_challenge"],
      code_challenge_method: params["code_challenge_method"],
      login_hint: params["login_hint"],
      dpop_jkt: jkt,
      expires_at: DateTime.add(now(), @par_ttl_seconds, :second)
    }

    case Request.changeset(attrs) |> Repo.insert() do
      {:ok, _row} -> {:ok, request_uri}
      {:error, _changeset} -> {:error, :request_not_stored}
    end
  end

  @doc """
  Reads a pushed request for the authorize page.

  Answers {:ok, request} or {:error, reason}. A request that was already
  approved or denied, or that has expired, is refused: it cannot be retried
  into a second code.
  """
  def fetch_request(request_uri, client_id) when is_binary(request_uri) do
    with true <- String.starts_with?(request_uri, @request_uri_prefix),
         {:ok, row} <- load_request(request_uri),
         :ok <- check_client(row, client_id, :invalid_request_uri),
         :ok <- check_request_fresh(row) do
      {:ok, row, request_uri}
    else
      false -> {:error, :invalid_request_uri}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_request(_request_uri, _client_id), do: {:error, :invalid_request_uri}

  @doc """
  Approves a pushed request for an account and mints the code.

  The account is the one the caller authenticated as. `login_hint` binds it
  when the client supplied one, so a flow that started with a handle cannot end
  up on a different account than the user asked for. Setting `did` and
  `code_hash` is one conditional update, so an approved request cannot be
  approved twice.
  """
  def approve(request_uri, client_id, %User{} = user) do
    with {:ok, row, _uri} <- fetch_request(request_uri, client_id),
         :ok <- check_hint(row, user),
         {:ok, code} <- spend_request(row, user.did) do
      {:ok,
       %{
         redirect_uri: row.redirect_uri,
         state: row.state,
         code: code,
         issuer: Pesque.base_url()
       }}
    end
  end

  @doc "Refuses a pushed request, which redirects back with `access_denied`."
  def deny(request_uri, client_id) do
    with {:ok, row, _uri} <- fetch_request(request_uri, client_id),
         true <- deny_request(row) do
      {:ok, %{redirect_uri: row.redirect_uri, state: row.state, error: "access_denied"}}
    else
      false -> {:error, :invalid_request_uri}
      {:error, reason} -> {:error, reason}
    end
  end

  defp spend_request(row, did) do
    code = "cod-" <> random(32)

    {count, _} =
      from(r in Request,
        where: r.id == ^row.id and is_nil(r.did) and is_nil(r.code_hash),
        where: r.expires_at > ^now()
      )
      |> Repo.update_all(
        set: [
          did: did,
          code_hash: Request.hash(code),
          code_expires_at: DateTime.add(now(), @code_ttl_seconds, :second)
        ]
      )

    if count == 1, do: {:ok, code}, else: {:error, :request_already_used}
  end

  # A denial marks the request spent without minting anything. It writes a DID
  # no account has rather than a boolean column, so the "already used" check
  # above is one condition and not two.
  defp deny_request(row) do
    {count, _} =
      from(r in Request, where: r.id == ^row.id and is_nil(r.did) and is_nil(r.code_hash))
      |> Repo.update_all(set: [did: "denied"])

    count == 1
  end

  @doc """
  Exchanges an authorization code for tokens.

  Validates PKCE, binds the session to the DPoP key the request was pushed
  with, and refuses a code that is spent, expired, or presented with a
  different verifier, client or redirect_uri.
  """
  def exchange_code(params, jkt) do
    with {:ok, client_id} <- required(params, "client_id"),
         {:ok, code} <- required(params, "code"),
         {:ok, verifier} <- required(params, "code_verifier"),
         {:ok, row} <- load_code(code),
         :ok <- check_client(row, client_id, :invalid_grant),
         :ok <- check_pkce(row, verifier),
         :ok <- check_code_redirect(row, params["redirect_uri"]),
         :ok <- check_jkt(row, jkt),
         true <- spend_code(row) do
      issue(row.did, row.client_id, row.scope, jkt, nil)
    else
      false -> {:error, :invalid_grant}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rotates a refresh token into a new pair.

  A refresh token that has already been spent is a replay: the whole session is
  revoked and the answer is `invalid_grant`, which is what the reference
  implementation does and what stops a stolen, already-used token from quietly
  renewing itself.
  """
  def refresh(params, jkt) do
    with {:ok, client_id} <- required(params, "client_id"),
         {:ok, token} <- required(params, "refresh_token"),
         {:ok, row} <- load_refresh(token),
         :ok <- check_client(row, client_id, :invalid_grant),
         :ok <- check_jkt(row, jkt),
         true <- spend_refresh(row) do
      issue(row.did, row.client_id, row.scope, jkt, row.session_id)
    else
      false -> {:error, :invalid_grant}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revokes a token.

  A refresh token revokes its whole session, access token or not: the session
  is the thing a user thinks they ended, and leaving its access tokens live
  after they asked for the session to end is not ending it. An unknown token
  answers `{:ok, nil}` rather than an error, because RFC 7009 says a server
  must not tell a caller whether the token it presented existed.
  """
  def revoke(token) when is_binary(token) do
    case Repo.get_by(Token, token_hash: Token.hash(token)) do
      nil ->
        {:ok, nil}

      %Token{kind: kind} = row ->
        revoke_where(if(kind == Token.refresh(), do: row.session_id, else: row.id))
    end
  end

  def revoke(_token), do: {:ok, nil}

  defp revoke_where(session_id) when is_binary(session_id) do
    {count, _} =
      from(t in Token, where: t.session_id == ^session_id and t.revoked == false)
      |> Repo.update_all(set: [revoked: true])

    {:ok, count}
  end

  defp revoke_where(id) do
    {count, _} =
      from(t in Token, where: t.id == ^id and t.revoked == false)
      |> Repo.update_all(set: [revoked: true])

    {:ok, count}
  end

  @doc """
  The claims a live access token carries, or {:error, :invalid_token}.

  The signature is checked against this server's published key, then the jti is
  looked up, so a revoked or expired token fails even though its signature is
  perfect. That is the cost of being able to revoke an individual access token,
  and the spec asks for individual revocation.
  """
  def verify_access_token(token) do
    with {:ok, header, claims, input, signature} <- Jwt.decode(token),
         "ES256" <- header["alg"],
         %{pub: pub} <- Keys.keypair(),
         true <- Jwt.verify_es256(input, signature, pub),
         true <- is_integer(claims["exp"]) and claims["exp"] > System.system_time(:second),
         {:ok, row} <- live_token(claims["jti"]) do
      {:ok, claims |> Map.put("scope", row.scope) |> Map.put("jkt", row.dpop_jkt)}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc "The DPoP key an access token is bound to."
  def jkt(claims), do: get_in(claims, ["cnf", "jkt"])

  defp live_token(jti) when is_binary(jti) do
    case Repo.get_by(Token, jti: jti) do
      %Token{revoked: false, kind: "access", expires_at: expires_at} = row ->
        if DateTime.before?(expires_at, DateTime.utc_now()) do
          {:error, :invalid_token}
        else
          {:ok, row}
        end

      _other ->
        {:error, :invalid_token}
    end
  end

  defp live_token(_jti), do: {:error, :invalid_token}

  # Everything an issued pair needs, in one place, so the code exchange and the
  # refresh cannot drift apart.
  defp issue(did, client_id, scope, jkt, session_id) do
    now = System.system_time(:second)
    session_id = session_id || random(16)
    jti = "tok-" <> random(16)
    refresh = "ref-" <> random(32)

    claims = %{
      "iss" => Pesque.base_url(),
      "sub" => did,
      "aud" => did,
      "jti" => jti,
      "iat" => now,
      "exp" => now + @access_ttl_seconds,
      "scope" => scope,
      "client_id" => client_id,
      "cnf" => %{"jkt" => jkt}
    }

    expires_at = DateTime.from_unix!(now + @refresh_ttl_seconds)
    inserted_at = now()
    access = Keys.sign(claims)

    rows = [
      %{
        # Hashed over the token as it is presented, not over the jti inside it:
        # revocation looks a token up by this hash, and a caller revoking an
        # access token holds the signed JWT and nothing else.
        token_hash: Token.hash(access),
        jti: jti,
        kind: Token.access(),
        did: did,
        client_id: client_id,
        scope: scope,
        dpop_jkt: jkt,
        session_id: session_id,
        expires_at: expires_at,
        inserted_at: inserted_at
      },
      %{
        token_hash: Token.hash(refresh),
        jti: "rt-" <> random(16),
        kind: Token.refresh(),
        did: did,
        client_id: client_id,
        scope: scope,
        dpop_jkt: jkt,
        session_id: session_id,
        expires_at: expires_at,
        inserted_at: inserted_at
      }
    ]

    case Repo.insert_all(Token, rows) do
      {2, _} ->
        {:ok,
         %{
           "access_token" => access,
           "token_type" => "DPoP",
           "refresh_token" => refresh,
           "expires_in" => @access_ttl_seconds,
           "scope" => scope,
           "sub" => did
         }}

      {_count, _} ->
        {:error, :token_not_stored}
    end
  end

  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_parameter, key}}
    end
  end

  defp check_response_type(%{"response_type" => "code"}), do: :ok
  defp check_response_type(_params), do: {:error, :unsupported_response_type}

  # PKCE is mandatory for every client in this profile and plain is not allowed,
  # so both halves are checked here rather than discovered at exchange time.
  defp check_pkce(%{"code_challenge" => challenge, "code_challenge_method" => "S256"})
       when is_binary(challenge) and challenge != "" do
    :ok
  end

  defp check_pkce(_params), do: {:error, :invalid_pkce}

  defp check_state(%{"state" => state}) when is_binary(state) and state != "", do: :ok
  defp check_state(_params), do: {:error, :missing_state}

  defp check_redirect_uri(metadata, redirect_uri) do
    if Client.redirect_uri_allowed?(metadata, redirect_uri) do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp check_declared_scope(metadata, scope) do
    if Client.scopes_declared?(metadata, scope) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  # A login_hint is not trusted to name an account that exists, only to name one
  # the user then has to authenticate as. Accounts.repo_did/1 consults the users
  # table, so a hint for an account this server does not host is refused before
  # the login page is shown.
  defp check_login_hint(nil), do: :ok

  defp check_login_hint(hint) when is_binary(hint) do
    case Accounts.repo_did(hint) do
      {:ok, _did} -> :ok
      {:error, _reason} -> {:error, :invalid_login_hint}
    end
  end

  defp check_login_hint(_hint), do: {:error, :invalid_login_hint}

  defp load_request(request_uri) do
    case Repo.get_by(Request, request_uri_hash: Request.hash(request_uri)) do
      nil -> {:error, :invalid_request_uri}
      row -> {:ok, row}
    end
  end

  defp check_client(%{client_id: client_id}, client_id, _reason), do: :ok
  defp check_client(_row, _client_id, reason), do: {:error, reason}

  defp check_request_fresh(%Request{did: nil, expires_at: expires_at}) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      {:error, :request_expired}
    else
      :ok
    end
  end

  defp check_request_fresh(_row), do: {:error, :request_already_used}

  defp check_hint(%Request{login_hint: nil}, _user), do: :ok

  defp check_hint(%Request{login_hint: hint}, %User{did: did}) do
    case Accounts.repo_did(hint) do
      {:ok, ^did} -> :ok
      _other -> {:error, :login_hint_mismatch}
    end
  end

  defp load_code(code) do
    case Repo.get_by(Request, code_hash: Request.hash(code)) do
      %Request{did: did, code_expires_at: expires_at} = row when is_binary(did) ->
        if is_nil(expires_at) or DateTime.before?(expires_at, DateTime.utc_now()) do
          {:error, :invalid_grant}
        else
          {:ok, row}
        end

      _other ->
        {:error, :invalid_grant}
    end
  end

  # RFC 7636 section 4.6: the verifier hashes to the challenge. Compared in
  # constant time because the challenge is a secret shared with the client.
  defp check_pkce(%Request{code_challenge: challenge}, verifier) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    if byte_size(computed) == byte_size(challenge) and
         Plug.Crypto.secure_compare(computed, challenge) do
      :ok
    else
      {:error, :invalid_code_verifier}
    end
  end

  defp check_code_redirect(%Request{redirect_uri: redirect_uri}, redirect_uri), do: :ok
  defp check_code_redirect(_row, _redirect_uri), do: {:error, :invalid_grant}

  # The token request must present a proof from the key the request was pushed
  # with. Without this, a proof captured from one client could be replayed
  # against another client's pushed request and would bind that session to the
  # attacker's key.
  defp check_jkt(%{dpop_jkt: jkt}, jkt), do: :ok
  defp check_jkt(_row, _jkt), do: {:error, :invalid_dpop_proof}

  defp spend_code(row) do
    {count, _} =
      from(r in Request, where: r.id == ^row.id and is_nil(r.used_at))
      |> Repo.update_all(set: [used_at: now()])

    count == 1
  end

  defp load_refresh(token) do
    case Repo.get_by(Token, token_hash: Token.hash(token)) do
      %Token{kind: "refresh", revoked: false} = row ->
        if DateTime.before?(row.expires_at, DateTime.utc_now()) do
          {:error, :invalid_grant}
        else
          {:ok, row}
        end

      _other ->
        {:error, :invalid_grant}
    end
  end

  defp spend_refresh(row) do
    {count, _} =
      from(t in Token, where: t.id == ^row.id and t.revoked == false and is_nil(t.used_at))
      |> Repo.update_all(set: [used_at: now()])

    if count == 1 do
      true
    else
      # A refresh token that is already spent or revoked, presented again, means
      # two parties hold it. The session goes.
      _ = revoke_where(row.session_id)
      false
    end
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
end
