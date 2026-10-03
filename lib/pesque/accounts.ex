defmodule Pesque.Accounts do
  @moduledoc "Account lifecycle and session issuance."

  import Ecto.Query

  alias Pesque.{Identity, Repo}
  alias Pesque.Accounts.{RefreshToken, User}

  @doc """
  Creates the single local account. The account's DID is the server DID;
  the handle must match the configured server handle.
  """
  def create_account(handle, email, password) do
    cond do
      Repo.aggregate(User, :count, :id) > 0 ->
        {:error, :account_exists}

      String.downcase(handle || "") != Identity.handle() ->
        {:error, :handle_not_available}

      byte_size(password || "") < 8 ->
        {:error, :password_too_short}

      true ->
        %{
          did: Identity.did(),
          handle: Identity.handle(),
          email: email,
          password_hash: Argon2.hash_pwd_salt(password)
        }
        |> User.changeset()
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            {:ok, _pid} = Pesque.RepoSupervisor.ensure_started(user.did)
            {:ok, user}

          error ->
            error
        end
    end
  end

  def get_user, do: Repo.one(from u in User, limit: 1)

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
