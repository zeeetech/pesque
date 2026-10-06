defmodule Pesque.Accounts do
  @moduledoc "Account lifecycle and session issuance."

  import Ecto.Query

  alias Pesque.Accounts.DeletionToken
  alias Pesque.Accounts.InviteCode
  alias Pesque.Accounts.RefreshToken
  alias Pesque.Accounts.User
  alias Pesque.Base32
  alias Pesque.Did
  alias Pesque.Events
  alias Pesque.Identity
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.Storage

  require Logger

  @deletion_token_ttl_seconds 24 * 60 * 60

  @doc """
  Creates a local account from a handle, an email, and a password.

  The handle is the whole identifier: a client sends alice.example.com and
  never sends a bare username, so the username is derived from it. Under
  path_multi the domain must equal the handle domain exactly, so a lookalike
  domain is rejected rather than normalized into acceptance.

  :invite_code, when given, is claimed for the new account's DID in the same
  transaction that inserts the account, so a code spent on an account that
  then fails to insert is spendable again.

  The order below is load-bearing. RepoServer.init/1 loads the key for the
  DID it is given, so the key file has to be claimed before the repo starts
  and the user row has to be committed before that. A failed insert leaves a
  key file nobody owns, and an orphan there makes the next attempt at the
  same handle fail on the exclusive create, so it is removed before
  returning.
  """
  def create_account(handle, email, password, opts \\ []) do
    with {:ok, identity} <- identity_for(handle),
         :ok <- check_password(password),
         :ok <- check_email(email),
         :ok <- check_available(identity, email),
         {:ok, key} <- claim_key(identity) do
      insert(identity, email, password, key.pub_multibase, Keyword.get(opts, :invite_code))
    end
  end

  @doc """
  Creates `code_count` invite codes, each good for `use_count` accounts, and
  answers them grouped by the account they were made for.

  A server whose registration is closed has no public way in, so this is how
  an operator hands accounts out. The codes are random base32, short enough to
  read over a voice call, and the unique index is what makes a guess against
  one of them fail rather than collide.

  `for_accounts` restricts the codes to those DIDs and answers one group per
  DID. A code made for nobody is spendable by any account, and its group names
  no account, because a code belonging to nobody cannot name one.
  """
  def create_invite_codes(code_count, use_count, for_accounts \\ [])

  def create_invite_codes(code_count, use_count, for_accounts)
      when is_integer(code_count) and code_count > 0 and
             is_integer(use_count) and use_count > 0 and is_list(for_accounts) do
    accounts = if for_accounts == [], do: [nil], else: for_accounts
    restricted = if for_accounts == [], do: nil, else: for_accounts

    groups =
      for account <- accounts do
        %{account: account, codes: insert_codes(code_count, use_count, restricted)}
      end

    {:ok, groups}
  end

  def create_invite_codes(code_count, _use_count, for_accounts)
      when is_integer(code_count) and code_count > 0 and is_list(for_accounts) do
    {:error, :invalid_use_count}
  end

  def create_invite_codes(code_count, _use_count, for_accounts)
      when is_integer(code_count) and is_list(for_accounts) do
    {:error, :invalid_code_count}
  end

  def create_invite_codes(_code_count, _use_count, _for_accounts),
    do: {:error, :invalid_code_count}

  defp insert_codes(code_count, use_count, restricted) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      for _ <- 1..code_count do
        row = %{code: random_code(), use_count: use_count, uses: 0, inserted_at: now}

        # Left out rather than written as nil, because the adapter dumps a nil
        # array as the JSON string "null" and the claim query asks IS NULL.
        if restricted, do: Map.put(row, :for_accounts, restricted), else: row
      end

    {_count, inserted} =
      Repo.insert_all(InviteCode, rows, on_conflict: :nothing, returning: [:code])

    Enum.map(inserted, & &1.code)
  end

  @doc """
  Claims one use of an invite code for `did`. A code with no uses left, one no
  row names, and one restricted to other DIDs all answer
  {:error, :invalid_invite_code}; the conditional update is what makes two
  callers racing for the last use of a code produce one account rather than
  two, and what makes the restriction and the count one statement.
  """
  def consume_invite_code(code, did) when is_binary(code) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(i in InviteCode,
        where: i.code == ^code and i.uses < i.use_count,
        where: is_nil(i.for_accounts) or ^did in i.for_accounts
      )
      |> Repo.update_all(inc: [uses: 1], set: [used_at: now, used_by: did])

    if count == 1, do: :ok, else: {:error, :invalid_invite_code}
  end

  def consume_invite_code(_code, _did), do: {:error, :invalid_invite_code}

  # Checked before anything else is touched, because the changeset would
  # otherwise reject it after a key file had already been claimed.
  defp check_email(email) when is_binary(email), do: :ok
  defp check_email(_email), do: {:error, :email_required}

  @doc "The account with a DID, or nil."
  def get_user(did), do: Repo.get_by(User, did: did)

  @doc """
  Whether an account's repo is served here.

  False for a DID this server does not host, because there is no account whose
  state could be active. A repo that has never been written to is active: the
  account exists and is not deactivated, which is a different thing from having
  no repo behind it and is what the callers answer separately.
  """
  def repo_active?(did) when is_binary(did) do
    match?(%User{active: true}, get_user(did))
  end

  def repo_active?(_did), do: false

  @doc """
  The DIDs of every hosted account that is deactivated, as a set.

  One query rather than one per DID: listRepos enumerates the whole server, so
  asking the users table per row would turn a single answer into a thousand.
  """
  def deactivated_dids do
    Repo.all(from u in User, where: u.active == false, select: u.did) |> MapSet.new()
  end

  @doc """
  The DIDs of every hosted account, ordered, for a whole-server listing.

  Only the DID is selected: this enumerates accounts to anyone who asks, so it
  must not be able to hand back a row carrying an email or a password hash.
  """
  def hosted_dids(limit, offset) do
    Repo.all(
      from u in User,
        order_by: [asc: u.did],
        limit: ^limit,
        offset: ^offset,
        select: u.did
    )
  end

  @doc "Every hosted DID, ordered. The whole set, for a maintenance sweep."
  def hosted_dids do
    Repo.all(from u in User, order_by: [asc: u.did], select: u.did)
  end

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
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The canonical DID of the local account named by an identifier, or {:error, reason}.

  Did.to_local_did/2 settles the syntax and whether the host is ours, and
  deliberately consults no database, so existence is settled here: a DID of
  the right shape naming no account is {:error, :not_found}, not an invitation.

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
          nil -> {:error, :not_found}
        end

      _handle ->
        # Matched the same way, for the same reason. Deriving the DID from
        # the live config and then looking that up means the port the server
        # runs on today decides whether an account created yesterday is
        # reachable at all. Only stored rows match, so a handle from another
        # network still answers {:error, :not_found}.
        case Repo.get_by(User, handle: String.downcase(String.trim(identifier))) do
          %User{did: did} -> {:ok, did}
          nil -> {:error, :not_found}
        end
    end
  end

  def repo_did(_identifier), do: {:error, :invalid_identifier}

  @doc """
  Whether the authenticated account owns the repo an identifier names.

  Both sides are canonical DIDs by the time they are compared, so no spelling
  of another account's repo can equal this one's. An unknown repo and another
  account's repo answer identically, so the write path cannot be used to ask
  which DIDs this server hosts.

  A deactivated account owns nothing writable. The check lives here rather than
  in the RepoServer because this is the one place every write already passes
  through, so a write stopped by deactivation is stopped by the same gate that
  decides who owns the repo, and not by a second rule kept somewhere else.
  """
  def authorize_write(%User{active: true, did: did}, repo) do
    case repo_did(repo) do
      {:ok, ^did} -> :ok
      _ -> {:error, :wrong_repo}
    end
  end

  def authorize_write(%User{}, _repo), do: {:error, :account_deactivated}

  @doc """
  Deactivates an account and announces it.

  The repo's rows, blocks and key stay: a deactivated account is still an
  account, getRepoStatus still answers for it, and activateAccount puts it back
  without anything having to be rebuilt. What stops is the write path, through
  authorize_write/2.

  deleteAfter is a recommendation about how long to hold the deactivated
  account, not an instruction: nothing here deletes anything on a schedule,
  and delete_account/4 remains the only path that destroys an account.

  The frame goes out after the row is updated, so a mirror that hears the
  deactivation and immediately asks getRepoStatus already reads it as inactive.
  """
  def deactivate_account(%User{} = user) do
    with {:ok, _user} <- set_active(user, false) do
      Events.emit_account(user.did, :deactivated)
      {:ok, user.did}
    end
  end

  @doc """
  Reactivates a deactivated account and announces it.

  Reverses deactivate_account/1. The repo was never torn down, so this is the
  row moving back and nothing else.
  """
  def activate_account(%User{} = user) do
    with {:ok, _user} <- set_active(user, true) do
      Events.emit_account(user.did, :activated)
      {:ok, user.did}
    end
  end

  defp set_active(%User{} = user, active) do
    case User.active_changeset(user, active) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :account_not_updated}
    end
  end

  @doc "The DID of the account owning a handle, or {:error, reason}. Consults the users table."
  def resolve_handle(handle) when is_binary(handle) do
    case Repo.get_by(User, handle: String.downcase(String.trim(handle))) do
      %User{did: did} -> {:ok, did}
      nil -> {:error, :not_found}
    end
  end

  def resolve_handle(_handle), do: {:error, :invalid_handle}

  @doc """
  Moves an account to a new handle and announces it.

  The new handle goes through the same two gates create_account/4 applies: the
  mode's own syntax and domain rules, and the users table for availability. The
  account's own row is excluded from the availability check, so setting the
  handle an account already has is a no-op rather than a collision with itself.

  Only the handle moves. The DID was minted once, when the account was created,
  and every record, block and meta row is keyed by it, so a handle change that
  re-derived the DID would strand all of them. Under path_multi that means the
  username stays the one the DID path carries and the handle is the alias that
  moves, which is what did:web allows: the path names the account, the handle
  is the name it is known by.
  """
  def update_handle(%User{} = user, handle) do
    with {:ok, identity} <- identity_for(handle),
         :ok <- check_reclaimable(identity, user) do
      case User.handle_changeset(user, %{handle: identity.handle}) |> Repo.update() do
        {:ok, updated} ->
          Events.emit_identity(updated.did, updated.handle)
          {:ok, updated}

        {:error, _changeset} ->
          {:error, :handle_not_available}
      end
    end
  end

  # The account's own rows do not count as taken, and the cross-column check
  # create_account/4 makes is kept: a handle that is another account's email
  # would make login unable to say which account a string means.
  defp check_reclaimable(identity, %User{did: did}) do
    taken =
      Repo.exists?(from u in User, where: u.did != ^did, where: u.handle == ^identity.handle)

    shadowed =
      Repo.exists?(from u in User, where: u.did != ^did, where: u.email == ^identity.handle)

    if taken or shadowed, do: {:error, :handle_not_available}, else: :ok
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

    case %{
           jti_hash: RefreshToken.hash_jti(jti),
           did: did,
           expires_at: DateTime.truncate(expires_at, :second)
         }
         |> RefreshToken.changeset()
         |> Repo.insert() do
      {:ok, _row} ->
        {:ok, %{access_jwt: access, refresh_jwt: refresh}}

      {:error, changeset} ->
        if Keyword.get(changeset.errors, :jti_hash) do
          {:error, :jti_taken}
        else
          {:error, :missing_fields}
        end
    end
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
         true <- revoke_live(row),
         {:ok, session} <- issue_session(user.did) do
      {:ok, session, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc """
  Issues a short-lived, single-use token authorizing this account's deletion.

  The lexicon says the token reaches the account holder by email. There is no
  mail here and no outbound HTTP, so the token is answered in the response body
  instead: a server that recorded a token it never delivered would leave the
  account undeletable, and the caller is already the authenticated owner.

  Only the hash is stored, so this table is not a set of live delete buttons.
  """
  def request_account_delete(%User{did: did}) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    expires_at =
      DateTime.shift(DateTime.utc_now(), second: @deletion_token_ttl_seconds)
      |> DateTime.truncate(:second)

    attrs = %{
      token_hash: DeletionToken.hash_token(token),
      did: did,
      expires_at: expires_at
    }

    case DeletionToken.changeset(attrs) |> Repo.insert() do
      {:ok, _row} -> {:ok, %{token: token, expires_at: expires_at}}
      {:error, _changeset} -> {:error, :deletion_token_failed}
    end
  end

  @doc """
  Deletes an account and everything it owns.

  Three things have to agree before anything is destroyed: the `did` names the
  authenticated account, the password is the account's, and the deletion token
  is this account's, unexpired and unused. The token is spent by a conditional
  update inside the deletion transaction, so two callers racing with one token
  produce one deletion and one :invalid_token.

  The order below is load-bearing. The repo process is stopped first, because a
  RepoServer holds the entry map and tid counter the rows are about to lose, and
  a write landing after the deletes would resurrect them. The `#account` frame
  goes out before the row disappears, so a mirror learns the account went away
  rather than only noticing it stopped. The rows go in one transaction, so a
  failure partway through leaves the account whole rather than a repo with no
  owner. The files go last, after the rows, so a crash between them leaves an
  orphan file no reader can reach rather than a row pointing at bytes that are
  gone.

  Event rows for the DID are deliberately kept. The firehose log is the record
  that the account was deleted; pruning the deleted repo's rows out of it would
  punch a hole in the sequence, and a consumer replaying from a cursor before
  that hole would never hear about the deletion at all. Retention is by age and
  already bounds the table.
  """
  def delete_account(%User{} = user, did, password, token) do
    with :ok <- check_did(user, did),
         :ok <- check_account_password(user, password),
         {:ok, row} <- fetch_deletion_token(user.did, token) do
      RepoServer.stop(user.did)
      Events.emit_account(user.did, :deleted)
      purge(user, row)
    end
  end

  defp check_did(%User{did: did}, did), do: :ok
  defp check_did(_user, _did), do: {:error, :wrong_account_did}

  defp check_account_password(%User{password_hash: hash}, password) when is_binary(password) do
    if Argon2.verify_pass(password, hash), do: :ok, else: {:error, :invalid_password}
  end

  defp check_account_password(_user, _password), do: {:error, :invalid_password}

  # Expiry is answered separately from validity: the lexicon names both, and a
  # client told ExpiredToken can ask for a new one instead of guessing whether
  # the token it holds is merely wrong.
  defp fetch_deletion_token(did, token) when is_binary(token) do
    case Repo.get_by(DeletionToken, token_hash: DeletionToken.hash_token(token)) do
      nil -> {:error, :invalid_token}
      %DeletionToken{did: ^did, used_at: nil} = row -> check_not_expired(row)
      %DeletionToken{} -> {:error, :invalid_token}
    end
  end

  defp fetch_deletion_token(_did, _token), do: {:error, :invalid_token}

  defp check_not_expired(%DeletionToken{expires_at: expires_at} = row) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      {:error, :expired_token}
    else
      {:ok, row}
    end
  end

  defp purge(user, token_row) do
    result =
      Repo.transaction(fn ->
        with true <- spend_token(token_row) do
          RepoStore.delete_repo_data!(user.did)
          Repo.delete_all(from t in RefreshToken, where: t.did == ^user.did)
          Repo.delete_all(from t in DeletionToken, where: t.did == ^user.did)
          Repo.delete!(user)
          :ok
        else
          false -> Repo.rollback(:invalid_token)
        end
      end)

    case result do
      {:ok, :ok} ->
        remove_files(user.did)
        Logger.info("account deleted", did: user.did)
        {:ok, user.did}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Single use is a conditional update, not a read followed by a write: two
  # callers holding the same token both read it unused, and only the one whose
  # update matches a row proceeds.
  defp spend_token(%DeletionToken{id: id}) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(t in DeletionToken, where: t.id == ^id and is_nil(t.used_at))
      |> Repo.update_all(set: [used_at: now])

    count == 1
  end

  # The blobs row is gone with the rest, so the bytes are unreachable already;
  # removing the directory is what stops them outliving the account on disk.
  defp remove_files(did) do
    _ = Keys.delete(did)

    _ =
      did
      |> then(&Path.join(Storage.blobs_dir(), Storage.digest_name(&1)))
      |> File.rm_rf()

    :ok
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
    case Keys.ensure(identity.did) do
      {:ok, key} ->
        {:ok, key}

      {:error, reason} ->
        Logger.error("the server signing key could not be loaded",
          did: identity.did,
          reason: inspect(reason)
        )

        {:error, :key_unavailable}
    end
  end

  defp claim_key(identity) do
    case Keys.create_exclusive(identity.did) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> {:error, :handle_not_available}
    end
  end

  # The invite code is claimed inside the transaction that inserts the
  # account, so a code spent on an insert that then failed goes back to being
  # spendable. The frame is announced after that transaction commits: a frame
  # for an account nobody can log into is worse than a late one.
  defp insert(identity, email, password, pub_multibase, invite_code) do
    result =
      Repo.transaction(fn ->
        with :ok <- consume_invite(invite_code, identity.did),
             {:ok, user} <- insert_user(identity, email, password, pub_multibase) do
          user
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, user} ->
        Logger.info("account created", did: user.did, handle: user.handle)
        Events.emit_account(user.did, :activated)
        {:ok, user}

      {:error, :invalid_invite_code} ->
        Keys.delete(identity.did)
        {:error, :invalid_invite_code}

      {:error, changeset} ->
        Keys.delete(identity.did)

        if email_taken?(changeset) do
          {:error, :email_taken}
        else
          {:error, :missing_fields}
        end
    end
  end

  defp insert_user(identity, email, password, pub_multibase) do
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
  end

  defp consume_invite(nil, _did), do: :ok
  defp consume_invite(code, did), do: consume_invite_code(code, did)

  defp random_code, do: Base32.encode(:crypto.strong_rand_bytes(5))

  defp email_taken?(changeset) do
    case Keyword.get(changeset.errors, :email) do
      {_msg, opts} when is_list(opts) -> opts[:constraint] == :unique
      _ -> false
    end
  end

  # alsoKnownAs is taken from the row rather than left to Did.did_document/2's
  # derivation from the username: updateHandle/2 moves the handle and the DID
  # path it is served at does not move with it, so the derivation would publish
  # a handle the account no longer answers to.
  defp document(user) do
    Did.did_document(Pesque.mode(), %{
      username: user.username,
      hostname: Pesque.hostname(),
      port: Pesque.port(),
      handle_domain: Pesque.handle_domain(),
      pub_multibase: user.pubkey_multibase
    })
    |> Map.put("alsoKnownAs", ["at://" <> user.handle])
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
