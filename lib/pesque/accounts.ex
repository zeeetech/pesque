defmodule Pesque.Accounts do
  @moduledoc "Account lifecycle and session issuance."

  import Ecto.Query

  alias Pesque.{Did, Identity, Keys, Repo}
  alias Pesque.Accounts.{RefreshToken, User}

  @doc """
  Creates a local account from a handle, an email, and a password.

  The handle is the whole identifier: a client sends alice.example.com and
  never sends a bare username, so the username is derived from it. Under
  path_multi the domain must equal the handle domain exactly, so a lookalike
  domain is rejected rather than normalized into acceptance.

  The order below is load-bearing. RepoServer.init/1 loads the key for the
  DID it is given, so the key file has to be claimed before the repo starts
  and the user row has to be committed before that. A failed insert leaves a
  key file nobody owns, and an orphan there makes the next attempt at the
  same handle fail on the exclusive create, so it is removed before
  returning.
  """
  def create_account(handle, email, password) do
    with {:ok, identity} <- identity_for(handle),
         :ok <- check_password(password),
         :ok <- check_available(identity),
         {:ok, key} <- claim_key(identity) do
      insert(identity, email, password, key.pub_multibase)
    end
  end

  def get_user, do: Repo.one(from u in User, limit: 1)

  @doc "The DID document of the account named by a username, or :error."
  def did_document_for(username) do
    with {:ok, username} <- Did.normalize_username(username),
         %User{} = user <- Repo.get_by(User, username: username) do
      {:ok,
       Did.did_document(Pesque.mode(), %{
         username: user.username,
         hostname: Pesque.hostname(),
         port: Pesque.port(),
         handle_domain: Pesque.handle_domain(),
         pub_multibase: user.pubkey_multibase
       })}
    else
      _ -> :error
    end
  end

  @doc "The DID of the account owning a handle, or :error. Consults the users table."
  def resolve_handle(handle) do
    case Repo.get_by(User, handle: String.downcase(String.trim(handle || ""))) do
      %User{did: did} -> {:ok, did}
      nil -> :error
    end
  end

  @doc "Verifies a handle/email + password pair. Constant-ish time by construction."
  def verify_login(identifier, password) do
    user =
      Repo.one(
        from u in User,
          where: u.handle == ^identifier or u.email == ^identifier
      )

    if user do
      if Argon2.verify_pass(password, user.password_hash), do: {:ok, user}, else: :error
    else
      Argon2.no_user_verify()
      :error
    end
  end

  @doc "Issues an access/refresh pair and registers the refresh jti as live."
  def issue_session(did) do
    now = System.system_time(:second)
    secret = Pesque.Secret.get()

    access =
      Pesque.Token.sign(
        %{
          "scope" => "com.atproto.access",
          "sub" => did,
          "iat" => now,
          "exp" => now + Pesque.Token.access_ttl_seconds()
        },
        secret
      )

    jti = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), Pesque.Token.refresh_ttl_seconds(), :second)

    refresh =
      Pesque.Token.sign(
        %{
          "scope" => "com.atproto.refresh",
          "sub" => did,
          "jti" => jti,
          "iat" => now,
          "exp" => now + Pesque.Token.refresh_ttl_seconds()
        },
        secret
      )

    %{
      jti_hash: RefreshToken.hash_jti(jti),
      did: did,
      expires_at: DateTime.truncate(expires_at, :second)
    }
    |> RefreshToken.changeset()
    |> Repo.insert!()

    %{access_jwt: access, refresh_jwt: refresh}
  end

  @doc "Rotates a live refresh token into a new pair. Reuse of a dead token fails."
  def rotate_session(refresh_jwt) do
    with {:ok, claims} <-
           Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh"),
         {:ok, row} <- fetch_live_refresh(claims["jti"]) do
      revoke!(row)
      {:ok, issue_session(claims["sub"])}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc "Revokes the presented refresh token (logout)."
  def revoke_session(refresh_jwt) do
    with {:ok, claims} <-
           Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh"),
         {:ok, row} <- fetch_live_refresh(claims["jti"]) do
      revoke!(row)
      :ok
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp identity_for(handle) when is_binary(handle) do
    case Pesque.mode() do
      :conformant_single -> single_account(handle)
      :path_multi -> path_multi_account(handle)
    end
  end

  defp identity_for(_handle), do: {:error, :handle_not_available}

  defp single_account(handle) do
    if String.downcase(String.trim(handle)) == String.downcase(Identity.handle()) do
      {:ok,
       %{mode: :conformant_single, did: Identity.did(), handle: Identity.handle(), username: nil}}
    else
      {:error, :handle_not_available}
    end
  end

  defp path_multi_account(handle) do
    handle = String.downcase(String.trim(handle))

    with [label, domain] <- String.split(handle, ".", parts: 2),
         {:ok, username} <- Did.normalize_username(label),
         true <- domain == String.downcase(Pesque.handle_domain()) do
      did =
        Did.did_for_username(
          :path_multi,
          Did.did_host(Pesque.hostname(), Pesque.port()),
          username
        )

      {:ok, %{mode: :path_multi, did: did, handle: handle, username: username}}
    else
      _ -> {:error, :handle_not_available}
    end
  end

  defp check_password(password) do
    if byte_size(password || "") < 8, do: {:error, :password_too_short}, else: :ok
  end

  # conformant_single has exactly one account and it is the server, so a
  # second attempt is an existing server rather than a taken handle.
  defp check_available(%{mode: mode} = identity) do
    taken =
      Repo.exists?(from u in User, where: u.did == ^identity.did or u.handle == ^identity.handle)

    if taken do
      {:error, if(mode == :conformant_single, do: :account_exists, else: :handle_not_available)}
    else
      :ok
    end
  end

  # The single account is the server and publishes the key created at boot,
  # so claiming a second one here would sign with a key the DID document
  # does not carry.
  defp claim_key(%{mode: :conformant_single} = identity) do
    Keys.ensure(identity.did)
  end

  defp claim_key(identity) do
    case Keys.create_exclusive(identity.did) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> {:error, :handle_not_available}
    end
  end

  defp insert(identity, email, password, pub_multibase) do
    %{
      did: identity.did,
      handle: identity.handle,
      username: identity.username,
      pubkey_multibase: pub_multibase,
      email: email,
      password_hash: Argon2.hash_pwd_salt(password)
    }
    |> User.changeset()
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, _pid} = Pesque.RepoSupervisor.ensure_started(user.did)
        {:ok, user}

      {:error, _changeset} ->
        Keys.delete(identity.did)
        {:error, :handle_not_available}
    end
  end

  defp fetch_live_refresh(jti) when is_binary(jti) do
    case Repo.get_by(RefreshToken, jti_hash: RefreshToken.hash_jti(jti)) do
      nil ->
        :error

      row ->
        if row.revoked or DateTime.compare(row.expires_at, DateTime.utc_now()) == :lt do
          :error
        else
          {:ok, row}
        end
    end
  end

  defp revoke!(row) do
    row
    |> RefreshToken.changeset(%{revoked: true})
    |> Repo.update!()
  end
end
