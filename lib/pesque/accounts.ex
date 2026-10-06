defmodule Pesque.Accounts do
  @moduledoc "Account lifecycle and session issuance."

  import Ecto.Query

  alias Pesque.Accounts.RefreshToken
  alias Pesque.Accounts.User
  alias Pesque.Did
  alias Pesque.Identity
  alias Pesque.Keys
  alias Pesque.Repo

  require Logger

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
         :ok <- check_email(email),
         :ok <- check_available(identity, email),
         {:ok, key} <- claim_key(identity) do
      insert(identity, email, password, key.pub_multibase)
    end
  end

  # Checked before anything else is touched, because the changeset would
  # otherwise reject it after a key file had already been claimed.
  defp check_email(email) when is_binary(email), do: :ok
  defp check_email(_email), do: {:error, :email_required}

  @doc "The account with a DID, or nil."
  def get_user(did), do: Repo.get_by(User, did: did)

  @doc """
  The DID document of the account named by a username, or of the account itself.

  The struct clause exists because the single account under conformant_single
  has no username, so its document is not reachable by one.
  """
  def did_document_for(%User{} = user), do: {:ok, document(user)}

  def did_document_for(username) do
    with {:ok, username} <- Did.normalize_username(username),
         %User{} = user <- Repo.get_by(User, username: username) do
      {:ok, document(user)}
    else
      _ -> :error
    end
  end

  @doc """
  The canonical DID of the local account named by an identifier, or :error.

  Did.to_local_did/2 settles the syntax and whether the host is ours, and
  deliberately consults no database, so existence is settled here: a DID of
  the right shape naming no account is :error, not an invitation.

  A DID is looked up by the string it is stored under, not by re-deriving it
  from the host and port the server currently runs on. An account's DID was
  minted once, when it was created, and did:web percent-encodes a non-default
  port, so re-deriving it turns moving from port 4000 to 443 into a total
  lockout: the stored rows still match nothing and every read answers
  RepoNotFound. Handles still go through the derivation, since a handle has to
  become a DID before it can be looked up.
  """
  def repo_did(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "did:web:" <> _rest ->
        # Matched exactly, not case-folded: did:web percent-encodes as
        # uppercase, so folding turns %3A into %3a and matches nothing.
        case Repo.get_by(User, did: String.trim(identifier)) do
          %User{did: did} -> {:ok, did}
          nil -> :error
        end

      _handle ->
        # Matched the same way, for the same reason. Deriving the DID from
        # the live config and then looking that up means the port the server
        # runs on today decides whether an account created yesterday is
        # reachable at all. Only stored rows match, so a handle from another
        # network still answers :error.
        case Repo.get_by(User, handle: String.downcase(String.trim(identifier))) do
          %User{did: did} -> {:ok, did}
          nil -> :error
        end
    end
  end

  def repo_did(_identifier), do: :error

  @doc """
  Whether the authenticated account owns the repo an identifier names.

  Both sides are canonical DIDs by the time they are compared, so no spelling
  of another account's repo can equal this one's. An unknown repo and another
  account's repo answer identically, so the write path cannot be used to ask
  which DIDs this server hosts.
  """
  def authorize_write(%User{did: did}, repo) do
    case repo_did(repo) do
      {:ok, ^did} -> :ok
      _ -> {:error, :wrong_repo}
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
    case find_by_identifier(identifier) do
      nil ->
        Argon2.no_user_verify()
        :error

      user ->
        if Argon2.verify_pass(password, user.password_hash), do: {:ok, user}, else: :error
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
    expires_at = DateTime.shift(DateTime.utc_now(), second: Pesque.Token.refresh_ttl_seconds())

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

  @doc """
  Rotates a live refresh token into a new pair. Reuse of a dead token fails.

  The account comes back with the pair because the caller has to answer as
  that account: the refresh token's subject is the only thing that says which
  one, and a subject naming no account is a dead token.
  """
  def rotate_session(refresh_jwt) do
    with {:ok, claims} <-
           Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh"),
         {:ok, row} <- fetch_live_refresh(claims["jti"]),
         %User{} = user <- get_user(claims["sub"]),
         true <- revoke_live(row) do
      {:ok, issue_session(user.did), user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc "Revokes the presented refresh token (logout)."
  def revoke_session(refresh_jwt) do
    with {:ok, claims} <-
           Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh"),
         {:ok, row} <- fetch_live_refresh(claims["jti"]),
         true <- revoke_live(row) do
      :ok
    else
      _ -> {:error, :invalid_token}
    end
  end

  # Two lookups on single-column unique indexes, never one query with an `or`
  # across both columns: that shape raises MultipleResultsError on a string
  # that is one account's handle and another's email, and login is reachable
  # unauthenticated, so the crash is a denial of service rather than a stack
  # trace nobody sees.
  #
  # The handle wins. It is the account's public name and the one a client
  # resolves a DID from, and create_account/3 refuses the collision that
  # would make the order matter for any account it creates. What is left is
  # rows that predate that check or come in through a path that bypasses it,
  # and those resolve to the same account on every call.
  #
  # The alternative is an account_identifiers table keyed by the identifier
  # itself, which makes the collision unrepresentable and the order moot.
  # Until there is an email-edit path it is not worth a third table.
  defp find_by_identifier(identifier) when is_binary(identifier) do
    Repo.get_by(User, handle: identifier) || Repo.get_by(User, email: identifier)
  end

  defp find_by_identifier(_identifier), do: nil

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
  #
  # An identifier is a handle or an email, so a string in one column can
  # collide with a string in the other and leave login unable to say which
  # account it means. create_account/3 refuses both directions, which keeps
  # the ambiguity out of the data; the comparison is exact because that is
  # the comparison find_by_identifier/1 makes.
  defp check_available(%{mode: mode} = identity, email) do
    taken =
      Repo.exists?(from u in User, where: u.did == ^identity.did or u.handle == ^identity.handle)

    if taken do
      {:error, if(mode == :conformant_single, do: :account_exists, else: :handle_not_available)}
    else
      check_identifier(identity, email)
    end
  end

  # A cross-column collision check: one account's handle must not become
  # another's email. Ecto refuses to build `== nil` from a pin, and the
  # conformant_single account has no handle, so each side is only compared
  # when present. Email itself is NOT NULL on the users table.
  defp check_identifier(identity, email) do
    cond do
      email != nil and Repo.exists?(from u in User, where: u.handle == ^email) ->
        {:error, :email_taken}

      identity.handle != nil and
          Repo.exists?(from u in User, where: u.email == ^identity.handle) ->
        {:error, :handle_not_available}

      true ->
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
      password_hash:
        Argon2.hash_pwd_salt(password, Application.get_env(:pesque, :argon2_opts, []))
    }
    |> User.changeset()
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        Logger.info("account created", did: user.did, handle: user.handle)
        {:ok, _pid} = Pesque.RepoSupervisor.ensure_started(user.did)
        {:ok, user}

      {:error, changeset} ->
        Keys.delete(identity.did)

        if email_taken?(changeset) do
          {:error, :email_taken}
        else
          {:error, :missing_fields}
        end
    end
  end

  defp email_taken?(changeset) do
    case Keyword.get(changeset.errors, :email) do
      {_msg, opts} when is_list(opts) -> opts[:constraint] == :unique
      _ -> false
    end
  end

  defp document(user) do
    Did.did_document(Pesque.mode(), %{
      username: user.username,
      hostname: Pesque.hostname(),
      port: Pesque.port(),
      handle_domain: Pesque.handle_domain(),
      pub_multibase: user.pubkey_multibase
    })
  end

  defp fetch_live_refresh(jti) when is_binary(jti) do
    case Repo.get_by(RefreshToken, jti_hash: RefreshToken.hash_jti(jti)) do
      nil ->
        :error

      row ->
        if row.revoked or DateTime.before?(row.expires_at, DateTime.utc_now()) do
          :error
        else
          {:ok, row}
        end
    end
  end

  # Atomic revoke: a concurrent refresh of the same token loses the race
  # instead of both pairs being issued.
  defp revoke_live(row) do
    {count, _} =
      from(t in RefreshToken, where: t.id == ^row.id and t.revoked == false)
      |> Repo.update_all(set: [revoked: true])

    count == 1
  end
end
