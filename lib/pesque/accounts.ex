defmodule Pesque.Accounts do
  @moduledoc "Account lifecycle and session issuance."

  import Ecto.Query

  alias Pesque.Accounts.AppPassword
  alias Pesque.Accounts.DeletionToken
  alias Pesque.Accounts.EmailToken
  alias Pesque.Accounts.InviteCode
  alias Pesque.Accounts.PasswordResetToken
  alias Pesque.Accounts.RefreshToken
  alias Pesque.Accounts.User
  alias Pesque.Base32
  alias Pesque.Did
  alias Pesque.Events
  alias Pesque.HandleResolver
  alias Pesque.Identity
  alias Pesque.Keys
  alias Pesque.OAuth
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.RepoSupervisor
  alias Pesque.Storage

  require Logger

  @deletion_token_ttl_seconds 24 * 60 * 60

  # The reference PDS gives its emailed confirmation and reset codes 15
  # minutes. An operator reading one out of a log or a CLI hands it over in
  # less, and a short life is the point: either code ends in a credential
  # change.
  @email_token_ttl_seconds 15 * 60

  # Materialised in memory before the single insert_all, so codeCount is
  # bounded by what one call may cost: 1000 codes is a few milliseconds,
  # 100_000 is seconds and tens of megabytes, and both are one client integer.
  @max_code_count 1_000

  # useCount multiplies what one code buys, so the bound is the size of the
  # promise a single code makes: a code that admits every account the server
  # will ever hold is closed registration with one extra step.
  @max_use_count 1_000

  @doc "Whether any account exists yet. Drives the first-boot hint."
  def empty?, do: not Repo.exists?(User)

  @doc """
  Creates a local account from a handle, an email, and a password.

  The handle is the whole identifier: the username is derived from it, and
  under path_multi the domain must equal the handle domain exactly, so a
  lookalike domain is rejected rather than normalized into acceptance.
  :invite_code, when given, is claimed in the same transaction that inserts
  the account, so a code spent on an insert that failed is spendable again.

  The order below is load-bearing. RepoServer.init/1 loads the key for the
  DID it is given, so the key file has to be claimed before the repo starts
  and the user row has to be committed before that; a failed insert removes
  the key file again, since an orphan there makes the next attempt at the
  same handle fail on the exclusive create. The hash is computed outside the
  transaction because argon2 would hold SQLite's single write lock for the
  whole hash, and a wrong invite code is answered before any hash is burned.
  """
  def create_account(handle, email, password, opts \\ []) do
    with {:ok, identity} <- identity_for(handle),
         :ok <- check_password(password),
         :ok <- check_email(email),
         :ok <- check_available(identity, email),
         {:ok, account} <- claim_account(identity),
         {:ok, password_hash} <- hash_password(password) do
      insert(
        account.identity,
        email,
        password_hash,
        account.key.pub_multibase,
        Keyword.get(opts, :invite_code),
        true,
        account.plc_operation
      )
    end
  end

  @doc """
  Creates the local account an imported DID lands on, deactivated and empty.

  The DID is the caller's, not one derived from the handle: an import moves an
  identity this server did not mint, and control of it is proven at the
  endpoint with a service-auth token signed by the DID's key. A handle under
  this server's own domain is resolved locally; any other handle has to
  resolve to the imported DID in both directions before a row is written.

  The account starts deactivated, so nothing is served or written until
  activateAccount; the repo is empty until importRepo fills it. The same key
  claim and password hash as create_account/4, and the same invite-code rules.
  """
  def create_imported_account(handle, email, password, did, opts \\ []) do
    with :ok <- check_import_did(did),
         :ok <- check_password(password),
         :ok <- check_email(email),
         {:ok, identity} <- imported_identity_for(handle, did),
         :ok <- check_available(identity, email),
         {:ok, key} <- claim_key(identity),
         {:ok, password_hash} <- hash_password(password) do
      insert(
        identity,
        email,
        password_hash,
        key.pub_multibase,
        Keyword.get(opts, :invite_code),
        false,
        nil
      )
    end
  end

  defp check_import_did(did) when is_binary(did) do
    if String.starts_with?(did, "did:"), do: :ok, else: {:error, :invalid_did}
  end

  defp check_import_did(_did), do: {:error, :invalid_did}

  # A handle under the server's own domain is resolved here, so it takes the
  # local derivation with no network. A foreign handle has no local username and
  # is proved by resolving it to the imported DID before the identity is built.
  # A foreign handle is only meaningful where accounts have their own DIDs: under
  # conformant_single the account is the server, and admitting one would be a
  # second account in a mode that serves one.
  defp imported_identity_for(handle, did) do
    cond do
      local_handle?(handle) ->
        with {:ok, identity} <- identity_for(handle), do: put_import_did(identity, did)

      Pesque.mode() == :path_multi ->
        with {:ok, identity} <- foreign_handle_identity(handle, did, nil),
             :ok <- HandleResolver.verify(identity.handle, did) do
          {:ok, identity}
        end

      true ->
        {:error, :disallowed_handle}
    end
  end

  # The identity_for/1 struct carries the DID this server would derive for the
  # handle. An import replaces it with the caller's, so the row, the key file
  # and every check below are about the imported identity and not the local one.
  defp put_import_did(identity, did), do: {:ok, %{identity | did: did}}

  # A foreign handle's stored spelling comes from the resolver, which settles
  # the syntax without the local-domain requirement. There is no local path
  # label behind it, so the username is nil; a did:plc document is keyed by the
  # stored DID and does not need one.
  defp foreign_handle_identity(handle, did, username) do
    with {:ok, normalized} <- HandleResolver.normalize(handle) do
      {:ok, %{mode: Pesque.mode(), did: did, handle: normalized, username: username}}
    end
  end

  # A handle this server already resolves: the bare handle domain, or a label
  # under it. The server owns that resolution, so no network call is needed.
  defp local_handle?(handle) when is_binary(handle) do
    domain = String.downcase(Pesque.handle_domain())
    normalized = handle |> String.trim() |> String.downcase()

    normalized == domain or String.ends_with?(normalized, "." <> domain)
  end

  defp local_handle?(_handle), do: false

  @doc """
  Creates `code_count` invite codes, each good for `use_count` accounts, and
  answers them grouped by the account they were made for.

  A server whose registration is closed has no public way in, so this is how
  an operator hands accounts out. `for_accounts` restricts the codes to those
  DIDs and answers one group per DID; a code made for nobody is spendable by
  any account. Both counts are bounded here because an authenticated caller
  is not the same thing as the operator.
  """
  def create_invite_codes(code_count, use_count, for_accounts \\ [])

  def create_invite_codes(code_count, use_count, for_accounts)
      when is_integer(code_count) and code_count > 0 and code_count <= @max_code_count and
             is_integer(use_count) and use_count > 0 and use_count <= @max_use_count and
             is_list(for_accounts) do
    accounts = if for_accounts == [], do: [nil], else: for_accounts
    restricted = if for_accounts == [], do: nil, else: for_accounts

    groups =
      for account <- accounts do
        %{account: account, codes: insert_codes(code_count, use_count, restricted)}
      end

    {:ok, groups}
  end

  # The bound is part of the guard rather than a check after it, so an
  # over-large count falls through to the clause naming the count rather than
  # being answered as a bad use_count.
  def create_invite_codes(code_count, _use_count, for_accounts)
      when is_integer(code_count) and code_count > 0 and code_count <= @max_code_count and
             is_list(for_accounts) do
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

  # Claims one use of an invite code for `did`. A code with no uses left, one
  # no row names, and one restricted to other DIDs all answer
  # {:error, :invalid_invite_code}; the conditional update means two callers
  # racing for the last use of a code produce one account rather than two,
  # and the restriction and the count are one statement.
  defp consume_invite_code(code, did) when is_binary(code) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(i in InviteCode,
        where: i.code == ^code and i.uses < i.use_count,
        where: is_nil(i.for_accounts) or ^did in i.for_accounts
      )
      |> Repo.update_all(inc: [uses: 1], set: [used_at: now, used_by: did])

    if count == 1, do: :ok, else: {:error, :invalid_invite_code}
  end

  defp consume_invite_code(_code, _did), do: {:error, :invalid_invite_code}

  # Checked before anything else is touched, because the changeset would
  # otherwise reject it after a key file had already been claimed.
  defp check_email(email) when is_binary(email), do: :ok
  defp check_email(_email), do: {:error, :email_required}

  @doc "The account with a DID, or nil."
  def get_user(did), do: Repo.get_by(User, did: did)

  @doc """
  Whether an account's repo is served here.

  False for a DID this server does not host: there is no account whose state
  could be active. A repo that has never been written to is active; the
  callers answer the empty-repo case separately.
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

  A DID is looked up by the string it is stored under, not re-derived from
  the host and port the server currently runs on: did:web percent-encodes a
  non-default port, so re-deriving it turns moving from port 4000 to 443
  into a total lockout. Handles still go through the derivation, since a
  handle has to become a DID before it can be looked up.
  """
  def repo_did(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    # Matched exactly, not case-folded: a DID is case-sensitive and did:web
    # percent-encodes as uppercase, so folding turns %3A into %3a and matches
    # nothing. Also never re-derived from the live config: the port the
    # server runs on today would decide whether an account created yesterday
    # is reachable at all. Only stored rows match.
    lookup =
      if String.starts_with?(identifier, "did:") do
        [did: identifier]
      else
        [handle: String.downcase(identifier)]
      end

    case Repo.get_by(User, lookup) do
      %User{did: did} -> {:ok, did}
      nil -> {:error, :not_found}
    end
  end

  def repo_did(_identifier), do: {:error, :invalid_identifier}

  @doc """
  Whether the authenticated account owns the repo an identifier names.

  Both sides are canonical DIDs by the time they are compared, and an unknown
  repo and another account's repo answer identically, so the write path
  cannot be used to ask which DIDs this server hosts.

  A deactivated account owns nothing writable. The check lives here rather
  than in the RepoServer because this is the one gate every write already
  passes through, so the deactivation rule is not a second rule kept
  somewhere else.
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

  The repo's rows, blocks and key stay: activateAccount puts it back without
  anything having to be rebuilt. What stops is the write path, through
  authorize_write/2. deleteAfter is a recommendation about how long to hold
  the deactivated account, not an instruction: nothing here deletes anything
  on a schedule, and delete_account/4 remains the only destructive path.

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
  row moving back and nothing else. The announcement is the `#account` frame
  followed by an empty commit: the spec pairs the two on reactivation, because
  a consumer that attached to the firehose live has only what arrives after it,
  and only a commit moves the repo it is serving.
  """
  def activate_account(%User{} = user) do
    with :ok <- verify_identity(user),
         {:ok, _user} <- set_active(user, true) do
      announce_active(user.did)
      {:ok, user.did}
    end
  end

  @doc """
  Announces an already-active account without changing it: the `#account` frame
  and the empty commit activate_account/1 makes after it flips the row.

  Used at the end of a migration, after the account is active here and the old
  PDS deactivated, so this PDS's activation is the last account event for the
  DID on the wire: a consumer that applies the deactivation the old PDS still
  emits would otherwise end with the account marked deactivated.
  """
  def announce_active(did) when is_binary(did) do
    Events.emit_account(did, :activated)
    announce_head(did)
    :ok
  end

  @doc """
  Replaces an account's password and ends every session it holds.

  The direct, operator-driven reset, for a caller that already holds the
  account. The spec's own reset goes through `reset_password_with_token/2`,
  which spends a code from requestPasswordReset first; both end in this write.

  The hash and the teardown are one operation from the operator's point of
  view: a reset that left the attacker's sessions live would not be a reset.
  The row update, the refresh tokens and the OAuth tokens are one
  transaction, so a crash between them cannot leave live sessions under a
  new password. The password goes through the same checks and the same hash
  as create_account/4, computed outside the transaction for the same reason
  it is there: argon2 must not hold SQLite's single write lock.
  """
  def reset_password(%User{} = user, password), do: apply_reset(user, password, fn -> :ok end)

  @doc """
  Resets an account's password using a code from requestPasswordReset.

  The code names the account, so no did or session is needed: the only proof
  is the token requestPasswordReset issued, and that is never answered to the
  anonymous caller. The spend and the write are one transaction, so a reset
  that fails does not leave the code consumed.

  Answers :ok or `{:error, reason}`; an unknown, spent or expired code is
  `:invalid_token` or `:expired_token`.
  """
  def reset_password_with_token(token, password) when is_binary(token) do
    with {:ok, row} <- fetch_password_reset_token(token),
         %User{} = user <- get_user(row.did) do
      apply_reset(user, password, fn -> spend_password_reset_token(row) end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  def reset_password_with_token(_token, _password), do: {:error, :invalid_token}

  # The write both reset flows share. `spend` is the code's conditional update
  # for the token flow and a no-op for the direct one; either way it runs
  # inside the same transaction as the write, so a code is never consumed by a
  # reset that did not land.
  defp apply_reset(%User{} = user, password, spend) do
    with :ok <- check_password(password),
         {:ok, password_hash} <- hash_password(password) do
      result =
        Repo.transaction(fn ->
          with :ok <- spend.() do
            case update_password(user, password_hash) do
              {:ok, _row} -> revoke_sessions(user.did)
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            :invalid_token -> Repo.rollback(:invalid_token)
          end
        end)

      case result do
        {:ok, :ok} ->
          Logger.info("password reset", did: user.did)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp update_password(user, password_hash) do
    case User.password_changeset(user, password_hash) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :account_not_updated}
    end
  end

  # Sessions are dead the moment their rows are: a refresh token whose row is
  # gone fails the lookup, and an OAuth token marked revoked fails its own.
  # Both tables are keyed by DID, so one pass each is the whole teardown.
  defp revoke_sessions(did) do
    Repo.delete_all(from t in RefreshToken, where: t.did == ^did)
    _ = OAuth.revoke_all(did)
    :ok
  end

  @doc """
  Issues the single-use code `confirm_email/3` spends.

  The lexicon emails this code to the account holder. There is no mail here and
  no email dependency, so the code goes to the operator instead: it is logged
  (the `token` metadata, info level) and mintable again through
  `pesque account email-token`. A self-hosted PDS's account holder is its
  operator, which is the assumption the email flow stood on.

  The token is stored hashed, expires in 15 minutes, and is single use. Answers
  `{:ok, %{token:, expires_at:}}` or `{:error, reason}`.
  """
  def request_email_confirmation(%User{} = user), do: issue_email_token(user)

  @doc """
  Confirms an account's email with a code from requestEmailConfirmation.

  The code is bound to the address it was minted for, so an email that is not
  this account's is refused before the code is touched: a caller cannot confirm
  an address the code does not name. The spend and the timestamp are one
  transaction, so a confirm that fails does not leave the code consumed.

  Answers :ok or `{:error, reason}`.
  """
  def confirm_email(%User{} = user, email, token) do
    with :ok <- check_email(email),
         :ok <- check_confirmation_address(user, email),
         {:ok, row} <- fetch_email_token(user.did, token) do
      result =
        Repo.transaction(fn ->
          with :ok <- spend_email_token(row) do
            case User.email_confirmed_changeset(user) |> Repo.update() do
              {:ok, _updated} -> :ok
              {:error, _changeset} -> Repo.rollback(:account_not_updated)
            end
          else
            :invalid_token -> Repo.rollback(:invalid_token)
          end
        end)

      case result do
        {:ok, :ok} ->
          Logger.info("email confirmed", did: user.did)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  The `tokenRequired` answer updateEmail reads, and the code it then needs.

  A confirmed address is the thing a stolen session must not be able to move,
  so moving it takes a code minted to that address: this issues one and answers
  `tokenRequired: true`. An account whose address was never confirmed has
  nothing to protect, so it answers `tokenRequired: false` and mints nothing;
  `updateEmail` then needs no token.

  Answers `{:ok, %{token_required: boolean}}`, carrying `:token` and
  `:expires_at` when one was issued, or `{:error, reason}`.
  """
  def request_email_update(%User{email_confirmed_at: nil}), do: {:ok, %{token_required: false}}

  def request_email_update(%User{} = user) do
    with {:ok, issued} <- issue_email_token(user),
         do: {:ok, Map.put(issued, :token_required, true)}
  end

  @doc """
  Updates an account's email, spending a code first when the current address is
  confirmed.

  A new address is unconfirmed by definition: it is only proven once a code
  minted to it is spent through confirmEmail, so the timestamp is cleared here
  rather than carried over. The spend and the write are one transaction, so a
  change that fails does not leave the code consumed, and the address cannot
  move without it.

  The new address must not collide with another account's email or handle, the
  same cross-namespace rule createAccount enforces. Answers `{:ok, user}` or
  `{:error, reason}`.
  """
  def update_email(%User{} = user, email, token) do
    with :ok <- check_email(email),
         :ok <- check_email_change(user, email),
         {:ok, requirement} <- update_email_requirement(user, token) do
      result =
        Repo.transaction(fn ->
          with :ok <- spend_update_token(requirement) do
            case User.email_changeset(user, email) |> Repo.update() do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(email_change_error(changeset))
            end
          else
            :invalid_token -> Repo.rollback(:invalid_token)
          end
        end)

      case result do
        {:ok, updated} ->
          Logger.info("email updated", did: updated.did)
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A confirmed address means the request must carry a code minted to it; an
  # unconfirmed one needs none. `nil` is the "no code" the transaction spends
  # as a no-op, so the two cases run one path.
  defp update_email_requirement(%User{email_confirmed_at: nil}, _token), do: {:ok, nil}

  defp update_email_requirement(%User{} = user, token) when is_binary(token) and token != "" do
    case fetch_email_token(user.did, token) do
      {:ok, %{email: email} = row} ->
        if email == user.email, do: {:ok, row}, else: {:error, :invalid_token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_email_requirement(%User{}, _token), do: {:error, :token_required}

  defp spend_update_token(nil), do: :ok
  defp spend_update_token(row), do: spend_email_token(row)

  # The request's email has to be the account's own, or the confirm names an
  # address this account does not have. That is an InvalidEmail, not a wrong
  # token: an input shape is wrong, and the code is left unspent so a correct
  # retry still works.
  defp check_confirmation_address(%User{email: email}, email), do: :ok
  defp check_confirmation_address(_user, _email), do: {:error, :invalid_email}

  # The new address must not be another account's handle: the create path keeps
  # that collision out and a move would reintroduce it. The unique index on the
  # email column covers one address belonging to one account; this covers the
  # address being another account's handle.
  defp check_email_change(%User{} = user, email) do
    if Repo.exists?(from u in User, where: u.did != ^user.did and u.handle == ^email) do
      {:error, :email_taken}
    else
      :ok
    end
  end

  defp email_change_error(changeset) do
    if email_taken?(changeset), do: :email_taken, else: :account_not_updated
  end

  @doc """
  Issues the single-use code `reset_password_with_token/2` spends.

  The requester is anonymous, so a miss is answered with :ok rather than an
  error: telling a stranger whether an address has an account here would be the
  enumeration the silent request exists to avoid. On a hit the code is logged
  and mintable through `pesque account reset-token`; it is never answered in
  the body, because that body goes to the requester.

  A `%User{}` issues for that account directly, which is how the CLI verb mints
  one. Answers `:ok`, `{:ok, %{token:, expires_at:}}` or `{:error, reason}`.
  """
  def request_password_reset(%User{} = user), do: issue_password_reset(user)

  def request_password_reset(email) when is_binary(email) do
    case Repo.get_by(User, email: email) do
      %User{} = user -> issue_password_reset(user)
      nil -> :ok
    end
  end

  defp issue_password_reset(%User{did: did}) do
    token = single_use_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@email_token_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      token_hash: PasswordResetToken.hash_token(token),
      did: did,
      expires_at: expires_at
    }

    case PasswordResetToken.changeset(attrs) |> Repo.insert() do
      {:ok, _row} ->
        Logger.info("password reset token issued", did: did, token: token)
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, _changeset} ->
        {:error, :reset_token_failed}
    end
  end

  # The one issuer both email request endpoints call. The code is bound to the
  # account's current address, which is what both confirmEmail and updateEmail
  # prove control of.
  defp issue_email_token(%User{did: did, email: email}) do
    token = single_use_token()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@email_token_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      token_hash: EmailToken.hash_token(token),
      did: did,
      email: email,
      expires_at: expires_at
    }

    case EmailToken.changeset(attrs) |> Repo.insert() do
      {:ok, _row} ->
        Logger.info("email token issued", did: did, token: token)
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, _changeset} ->
        {:error, :email_token_failed}
    end
  end

  defp fetch_email_token(did, token) when is_binary(token) do
    case Repo.get_by(EmailToken, token_hash: EmailToken.hash_token(token)) do
      nil -> {:error, :invalid_token}
      %EmailToken{did: ^did, used_at: nil} = row -> check_token_not_expired(row)
      %EmailToken{} -> {:error, :invalid_token}
    end
  end

  defp fetch_email_token(_did, _token), do: {:error, :invalid_token}

  # The caller guards that the token is a binary, so this clause is the whole
  # lookup: a token that names no row, was already spent, or has expired is
  # each its own refusal.
  defp fetch_password_reset_token(token) when is_binary(token) do
    case Repo.get_by(PasswordResetToken, token_hash: PasswordResetToken.hash_token(token)) do
      nil -> {:error, :invalid_token}
      %PasswordResetToken{used_at: nil} = row -> check_token_not_expired(row)
      %PasswordResetToken{} -> {:error, :invalid_token}
    end
  end

  # Single use is a conditional update, not a read followed by a write: two
  # callers holding one code both read it unused, and only the one whose update
  # matches a row proceeds.
  defp spend_email_token(%EmailToken{id: id}) do
    spend_single_use_token(EmailToken, id)
  end

  defp spend_password_reset_token(%PasswordResetToken{id: id}) do
    spend_single_use_token(PasswordResetToken, id)
  end

  defp spend_single_use_token(schema, id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(t in schema, where: t.id == ^id and is_nil(t.used_at))
      |> Repo.update_all(set: [used_at: now])

    if count == 1, do: :ok, else: :invalid_token
  end

  # Expiry is answered separately from validity: the lexicon names both, and a
  # caller told ExpiredToken asks for a new code instead of guessing whether
  # the one it holds is merely wrong.
  defp check_token_not_expired(%{expires_at: expires_at} = row) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      {:error, :expired_token}
    else
      {:ok, row}
    end
  end

  defp single_use_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # A did:plc account is activated only once the directory's document names
  # this server as its PDS, or every client resolves the account away from
  # here. A did:web account's document is served and derived here, so there
  # is nothing to fetch.
  defp verify_identity(%User{did: "did:plc:" <> _} = user), do: Pesque.Plc.verify_pds(user.did)
  defp verify_identity(%User{}), do: :ok

  defp set_active(%User{} = user, active) do
    case User.active_changeset(user, active) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :account_not_updated}
    end
  end

  # The migration spec asks a reactivated account to put a `#commit` next to
  # the `#account` frame, so a consumer that attached to the firehose live
  # sees the repo move. Without it a relay that never ingests anything leaves
  # the host at `offline` forever: the account is active here and invisible
  # on the network. Best effort, like the frame above: the account is already
  # active, and a head that cannot advance is a storage problem to log.
  defp announce_head(did) do
    case RepoSupervisor.ensure_started(did) do
      {:ok, pid} ->
        case RepoServer.announce(pid) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.warning("empty commit on activation failed",
              did: did,
              reason: inspect(reason)
            )
        end

      {:error, reason} ->
        Logger.warning("repo could not start to announce activation",
          did: did,
          reason: inspect(reason)
        )
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
  Whether a handle is free to register here.

  True when the handle's label and domain are valid for this server and no
  account already holds it, as a handle or as an email. The same gates
  create_account/4 applies, so a client that asks before it commits gets the
  answer the commit would give.
  """
  def handle_available?(handle) when is_binary(handle) do
    case identity_for(handle) do
      {:ok, identity} -> check_available(identity, nil) == :ok
      {:error, _reason} -> false
    end
  end

  def handle_available?(_handle), do: false

  @doc """
  Available handles to offer when `handle` is taken, shaped for
  com.atproto.temp.checkHandleAvailability.

  Candidates are the handle with a numeric or random suffix, plus one built
  from the email's local part when one is given, and only the ones this server
  would actually accept are returned. A handle on a foreign domain has no local
  candidates to vary, so it answers none.
  """
  def handle_suggestions(handle, email \\ nil) do
    case local_label(handle) do
      {:ok, label, domain} ->
        taken = String.downcase(String.trim(handle))

        label
        |> candidates(domain, email)
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.reject(fn {candidate, _method} -> candidate == taken end)
        |> Enum.filter(fn {candidate, _method} -> handle_available?(candidate) end)
        |> Enum.take(5)
        |> Enum.map(fn {candidate, method} -> %{"handle" => candidate, "method" => method} end)

      :error ->
        []
    end
  end

  # Only a handle under this server's own domain has local variants worth
  # offering; a foreign handle is registered as-is or not at all.
  defp local_label(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.downcase()
    domain = String.downcase(Pesque.handle_domain())

    with [label, ^domain] <- String.split(normalized, ".", parts: 2),
         {:ok, _username} <- Did.normalize_username(label) do
      {:ok, label, domain}
    else
      _ -> :error
    end
  end

  defp local_label(_handle), do: :error

  defp candidates(label, domain, email) do
    email_candidates(email, domain) ++ numbered(label, domain) ++ suffixed(label, domain)
  end

  defp email_candidates(email, domain) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, _domain] ->
        normalized = local |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
        if normalized == "", do: [], else: [{normalized <> "." <> domain, "email"}]

      _ ->
        []
    end
  end

  defp email_candidates(_email, _domain), do: []

  defp numbered(label, domain) do
    for _ <- 1..3,
        do: {label <> Integer.to_string(:rand.uniform(90) + 10) <> "." <> domain, "generated"}
  end

  defp suffixed(label, domain) do
    for _ <- 1..3 do
      suffix = Base32.encode(:crypto.strong_rand_bytes(3))
      {label <> suffix <> "." <> domain, "generated"}
    end
  end

  @doc """
  The invite codes earmarked for an account, oldest first.

  pesque's codes are minted by the operator, not by accounts, so "the account's
  codes" are the ones whose `for_accounts` names it: a code created for nobody
  belongs to no account and is not returned. `:include_used` (default true)
  drops codes with no uses left when false.
  """
  def invite_codes_for(did, opts \\ []) when is_binary(did) do
    query =
      from i in InviteCode,
        where: ^did in i.for_accounts,
        order_by: [asc: i.inserted_at]

    query =
      if Keyword.get(opts, :include_used, true),
        do: query,
        else: where(query, [i], i.uses < i.use_count)

    Repo.all(query)
  end

  @doc """
  Moves an account to a new handle and announces it.

  The new handle goes through the same two gates create_account/4 applies: the
  mode's own syntax and domain rules, and the users table for availability. The
  account's own row is excluded from the availability check, so setting the
  handle an account already has is a no-op rather than a collision with itself.
  A did:plc account may move to a handle on a foreign domain; a did:web
  account keeps a handle under this server's domain, because its document is
  served here.

  Only the handle moves. The DID was minted once, when the account was created,
  and every record, block and meta row is keyed by it, so a handle change that
  re-derived the DID would strand all of them.
  """
  def update_handle(%User{} = user, handle) do
    with {:ok, identity} <- update_handle_identity(user, handle),
         :ok <- check_reclaimable(identity, user),
         :ok <- require_handle_points_here(user, identity),
         {:ok, operation} <- update_plc_operation(user, identity.handle),
         {:ok, updated} <- write_handle(user, identity.handle, operation) do
      Events.emit_identity(updated.did, updated.handle)
      {:ok, updated}
    end
  end

  # A foreign handle is only reachable for a did:plc account: a did:web
  # account's handle is derived from the local domain and its document served
  # here, so a foreign handle would name a document this server does not own.
  defp update_handle_identity(%User{did: "did:plc:" <> _} = user, handle) do
    if local_handle?(handle) do
      identity_for(handle)
    else
      foreign_handle_identity(handle, user.did, user.username)
    end
  end

  defp update_handle_identity(%User{}, handle), do: identity_for(handle)

  # The handle has to already resolve to this account before the PLC operation
  # publishes it, otherwise a directory that accepted the operation would name a
  # handle this server's own resolution does not, and the row would be the only
  # place the two disagree. Checked before the operation, not after, so a refused
  # check leaves the directory untouched. A local handle is resolved by this
  # server and a did:web document is served here, so neither needs the check.
  defp require_handle_points_here(%User{did: "did:plc:" <> _} = user, %{handle: handle}) do
    if local_handle?(handle), do: :ok, else: HandleResolver.resolves_to?(handle, user.did)
  end

  defp require_handle_points_here(%User{}, _identity), do: :ok

  # The PLC operation is written before the row. If the directory refuses it
  # nothing local moves, so the handle this server resolves never disagrees
  # with the handle the DID document claims.
  defp update_plc_operation(%User{did: "did:plc:" <> _} = user, handle),
    do: Pesque.Plc.update_handle(user, handle)

  defp update_plc_operation(%User{}, _handle), do: {:ok, nil}

  defp write_handle(user, handle, operation) do
    overrides =
      if operation,
        do: %{handle: handle, plc_operation: operation},
        else: %{handle: handle}

    case User.handle_changeset(user, overrides) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :handle_not_available}
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
        no_user_verify()
        :error

      user ->
        if verify_pass(password, user.password_hash), do: {:ok, user}, else: :error
    end
  end

  @doc """
  Verifies a handle/email + password pair where the password may also be one of
  the account's app passwords.

  Answers {:ok, user, app_password} or :error; a nil app password means the
  account password matched, and a non-nil one is the credential the session
  must be narrowed by. This is the createSession check and nothing else's: the
  OAuth authorize page deliberately keeps verify_login/2, because an app
  password approving an OAuth request is the app-password reduction undone.
  """
  def verify_session_credentials(identifier, password) do
    case find_by_identifier(identifier) do
      nil ->
        no_user_verify()
        :error

      user ->
        if verify_pass(password, user.password_hash) do
          {:ok, user, nil}
        else
          case verify_app_password(user.did, password) do
            %AppPassword{} = app_password -> {:ok, user, app_password}
            nil -> :error
          end
        end
    end
  end

  # One sha256 and one indexed lookup, not a walk over argon2 verifies: the
  # password is a server-generated secret of the same entropy class as a
  # refresh jti, and an unauthenticated wrong guess already paid the argon2
  # of the account check. The second clause turns a non-binary password (only
  # reachable from a direct caller; the controller guards it) into an :error
  # rather than a raise.
  defp verify_app_password(did, password) when is_binary(did) and is_binary(password) do
    Repo.get_by(AppPassword, did: did, password_hash: AppPassword.hash_password(did, password))
  end

  defp verify_app_password(_did, _password), do: nil

  @doc """
  Creates a named app password. The password is answered once, in this result,
  and is unrecoverable afterwards: only its hash is stored.

  `privileged` decides the tier of every session opened with it (see
  issue_session/2). A name the account already uses is refused, so a client
  cannot silently replace a credential by re-using its name; after a revoke,
  the name is free again.
  """
  @spec create_app_password(User.t(), binary(), boolean()) ::
          {:ok,
           %{name: binary(), password: binary(), privileged: boolean(), created_at: DateTime.t()}}
          | {:error,
             :app_password_name_taken | :app_password_name_required | :app_password_not_created}
  def create_app_password(%User{did: did}, name, privileged)
      when is_binary(name) and is_boolean(privileged) do
    password = random_app_password()

    attrs = %{
      did: did,
      name: name,
      password_hash: AppPassword.hash_password(did, password),
      privileged: privileged
    }

    case AppPassword.changeset(attrs) |> Repo.insert() do
      {:ok, row} ->
        {:ok,
         %{
           name: row.name,
           password: password,
           privileged: row.privileged,
           created_at: row.inserted_at
         }}

      {:error, changeset} ->
        cond do
          app_password_name_taken?(changeset) -> {:error, :app_password_name_taken}
          changeset.errors[:name] -> {:error, :app_password_name_required}
          true -> {:error, :app_password_not_created}
        end
    end
  end

  def create_app_password(%User{}, _name, _privileged), do: {:error, :app_password_name_required}

  # unique_constraint([:did, :name]) puts its error under the first field of
  # the list, so the taken check looks at both keys. The (did, password_hash)
  # constraint surfaces the same way and is a collision too, though a random
  # password makes reaching it a curiosity rather than a path.
  defp app_password_name_taken?(changeset) do
    Enum.any?([:did, :name], fn field ->
      case Keyword.get(changeset.errors, field) do
        {_msg, opts} when is_list(opts) -> opts[:constraint] == :unique
        _ -> false
      end
    end)
  end

  # Reference parity, xxxx-xxxx-xxxx-xxxx: 80 bits of entropy in four
  # dash-separated groups. The dashes make it recognizable to humans and
  # clients, but the server never branches on the format; login hashes
  # whatever string arrives.
  defp random_app_password do
    :crypto.strong_rand_bytes(10)
    |> Base32.encode()
    |> String.split(~r/.{4}/, include_captures: true, trim: true)
    |> Enum.join("-")
  end

  @doc "Every app password for an account, newest first. The hashes stay in the rows; only this server reads them."
  @spec list_app_passwords(binary()) :: [AppPassword.t()]
  def list_app_passwords(did) when is_binary(did) do
    Repo.all(
      from p in AppPassword, where: p.did == ^did, order_by: [desc: p.inserted_at, desc: p.id]
    )
  end

  @doc """
  Revokes an app password by name, and every session opened with it, in one
  transaction: a revoked credential whose refresh tokens lived on would be a
  revocation that changed nothing for a logged-in client.

  Idempotent: a name no row answers is the state the caller asked for, so it is
  still :ok. OAuth tokens are not touched, because an app password never opens
  an OAuth session.
  """
  @spec revoke_app_password(User.t(), binary()) :: :ok
  def revoke_app_password(%User{did: did}, name) when is_binary(name) do
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from p in AppPassword, where: p.did == ^did and p.name == ^name)

        Repo.delete_all(
          from t in RefreshToken, where: t.did == ^did and t.app_password_name == ^name
        )
      end)

    :ok
  end

  def revoke_app_password(%User{}, _name), do: {:error, :app_password_name_required}

  # A non-string password raises ArgumentError out of the NIF, and only on the
  # branch that found an account: {"identifier":"nosuch","password":[]} is a
  # clean 401 and the same body with a real handle is a 500, which is an
  # unauthenticated oracle for which handles exist on a closed server. The
  # controller answers 400 for it, and this is the second lock on the same
  # door for every other caller.
  defp verify_pass(password, hash) when is_binary(password) do
    with_hash_permit(fn -> Argon2.verify_pass(password, hash) end)
  end

  defp verify_pass(_password, _hash), do: false

  # The one place argon2 options are read. Both the real hash and the dummy
  # verify have to run at the same cost or the timing defence is not one, so
  # no_user_verify gets the same opts (Comeonin.no_user_verify/1 is
  # hash_pwd_salt("", opts)). m_cost is an exponent of KiB, so m_cost 16 is
  # 65536 KiB per hash: configurable because the right number is a function
  # of the box, and anything above about m_cost 15 wants the permit count
  # looked at again.
  @doc false
  def argon2_opts, do: Application.get_env(:pesque, :argon2_opts, [])

  # argon2 is memory-hard: one verify holds 64 MiB at the defaults, and
  # nothing above this module bounds how many logins a client has in flight
  # (Bandit takes no connection cap, and the session rate limit bounds volume
  # rather than concurrency), so a hundred concurrent createSession calls is
  # several GiB of RSS. A counting semaphore via :atomics, not a pool of
  # workers: a permit costs one atomic add, and there is nothing to supervise
  # and no mailbox to serialise. The waiter sleeps between attempts rather
  # than spinning; the hashes want the cores. Sized against the schedulers,
  # floored at 2 for a one-core box, and capped so a many-core machine does
  # not size the gate by hardware instead of by memory.
  @argon2_permit_floor 2
  @argon2_permit_ceiling 8
  @argon2_permit_retry_ms 5
  @argon2_permits {__MODULE__, :argon2_permits}

  @doc false
  def argon2_permit_limit,
    do: min(@argon2_permit_ceiling, max(@argon2_permit_floor, System.schedulers_online()))

  defp with_hash_permit(fun) do
    acquire_hash_permit()
    # Released in an after, so a raise out of the NIF cannot leak a permit and
    # wedge the gate for every login after it.
    try do
      fun.()
    after
      :atomics.sub(hash_permits(), 1, 1)
    end
  end

  defp acquire_hash_permit do
    permits = hash_permits()
    limit = argon2_permit_limit()

    if :atomics.add_get(permits, 1, 1) <= limit do
      :ok
    else
      # Handed straight back rather than held while waiting, so a caller that
      # lost the race does not shrink the gate for everyone queued behind it.
      :atomics.sub(permits, 1, 1)
      Process.sleep(@argon2_permit_retry_ms)
      acquire_hash_permit()
    end
  end

  # A plain put plus a re-read rather than put_new/2, which is OTP 28 and up.
  # Two processes racing install equivalent counters and the value read back is
  # the one that won, so every later caller converges on a single budget.
  defp hash_permits do
    case :persistent_term.get(@argon2_permits, nil) do
      nil ->
        :persistent_term.put(@argon2_permits, :atomics.new(1, signed: false))
        :persistent_term.get(@argon2_permits)

      permits ->
        permits
    end
  end

  # The dummy verify for an identifier no row names. Same options as the real
  # hash, same gate, for the same reason: it has to be indistinguishable from
  # a real one in both cost and timing.
  defp no_user_verify, do: with_hash_permit(fn -> Argon2.no_user_verify(argon2_opts()) end)

  # No non-binary clause: check_password/1 runs first in the create_account/4
  # chain and answers one, so a non-string cannot reach here. That is the
  # reason the raise is gone from this path rather than merely caught.
  defp hash_password(password) when is_binary(password) do
    hash = with_hash_permit(fn -> Argon2.hash_pwd_salt(password, argon2_opts()) end)
    {:ok, hash}
  end

  @doc """
  Issues an access/refresh pair and registers the refresh jti as live.

  The session is narrowed to the app password it was opened with: the access
  token carries the tier as its scope claim (the same claim the plug reads
  for OAuth tokens), and the refresh row names the credential, so rotating
  re-reads the credential's privilege and revoking it kills the session.
  """
  def issue_session(did, opts \\ [])

  def issue_session(did, opts) do
    app_password = Keyword.get(opts, :app_password)
    now = System.system_time(:second)
    secret = Pesque.Secret.get()

    access =
      Pesque.Token.sign(
        %{
          "scope" => session_scope(app_password),
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
           expires_at: DateTime.truncate(expires_at, :second),
           app_password_name: app_password && app_password.name
         }
         |> RefreshToken.changeset()
         |> Repo.insert() do
      {:ok, _row} ->
        {:ok, %{access_jwt: access, refresh_jwt: refresh}}

      {:error, _changeset} ->
        {:error, :session_not_issued}
    end
  end

  # The tier ladder, one place: the account password is full access, an app
  # password is the transition:generic grant set the oauth spec defines as
  # the app-password authorization level, and a privileged one is trusted
  # with the account state a password login reaches (minus creating app
  # passwords, which the plug answers with the :full_session requirement,
  # not a grant).
  defp session_scope(nil), do: "com.atproto.access"
  defp session_scope(%AppPassword{privileged: true}), do: "com.atproto.appPassPrivileged"
  defp session_scope(%AppPassword{}), do: "com.atproto.appPass"

  @doc """
  Rotates a live refresh token into a new pair. Reuse of a dead token fails.

  The account comes back with the pair because the caller has to answer as
  that account: the refresh token's subject is the only thing that says which
  one, and a subject naming no account is a dead token.

  The row's own did is compared to the subject rather than assumed. The two
  cannot disagree today, since this server signed the token and the jti is
  unique, but a mismatch here is the one thing that would hand one account's
  session to another, and the column is written and indexed, so reading it
  keeps the index from migration 010 worth anything.
  """
  def rotate_session(refresh_jwt) do
    with {:ok, claims} <-
           Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh"),
         {:ok, row} <- fetch_live_refresh(claims["jti"]),
         true <- row.did == claims["sub"],
         %User{} = user <- get_user(claims["sub"]),
         {:ok, app_password} <- session_credential(row),
         true <- revoke_live(row),
         {:ok, session} <- issue_session(user.did, app_password: app_password) do
      {:ok, session, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  # The refresh row names the credential the session was opened with. No name
  # is a password-login session; a name whose row is gone is a dead session,
  # not a full one (revoking deletes both rows together, so this is defense,
  # but the failure must fail closed). Re-reading the row also means a
  # privilege edited by an operator propagates at the next rotation.
  defp session_credential(%RefreshToken{app_password_name: nil}), do: {:ok, nil}

  defp session_credential(%RefreshToken{did: did, app_password_name: name}) do
    case Repo.get_by(AppPassword, did: did, name: name) do
      %AppPassword{} = app_password -> {:ok, app_password}
      nil -> {:error, :invalid_token}
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
  gone. Event rows are kept: the firehose log is the record the account was
  deleted, and pruning it would punch a hole in the sequence a consumer
  replaying from before the hole would never hear about.
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

  # Through verify_pass/2, so a delete is a gated hash like every other one on a
  # request path: deleteAccount carries no rate limit, and an ungated verify
  # here is 64 MiB per request bought with nothing. The non-binary password is
  # answered there too, so no second clause is needed.
  defp check_account_password(%User{password_hash: hash}, password) do
    if verify_pass(password, hash), do: :ok, else: {:error, :invalid_password}
  end

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
          Repo.delete_all(from p in AppPassword, where: p.did == ^user.did)
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
    _ = Pesque.Plc.Keys.delete(did)

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

  # One resolution for every shape login accepts, so the OAuth login_hint check
  # and the login it guards cannot disagree about what names an account: a did
  # matched exactly, a handle case-insensitively (handles are case-insensitive
  # on the wire), an email as stored. repo_did/1 already owns the did/handle
  # half, so this reuses it rather than growing a second, drifting copy.
  #
  # Two lookups on single-column unique indexes, never one query with an `or`
  # across both columns: that shape raises MultipleResultsError on a string
  # that is one account's handle and another's email, and login is reachable
  # unauthenticated, so the crash is a denial of service rather than a stack
  # trace nobody sees. The handle wins: create_account/3 refuses the collision
  # that would make the order matter, so what is left resolves to the same
  # account on every call. An account_identifiers table would make the
  # collision unrepresentable, but until there is an email-edit path it is
  # not worth a third table.
  defp find_by_identifier(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    case repo_did(identifier) do
      {:ok, did} -> get_user(did)
      {:error, _reason} -> Repo.get_by(User, email: identifier)
    end
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

  # A binary rather than a `password || ""` fallback into byte_size/1: a
  # non-string is a malformed request, not a raise, and byte_size/1 on a list
  # raises before anything downstream gets the chance to answer 400 for it.
  defp check_password(password) when is_binary(password) do
    if byte_size(password) < 8, do: {:error, :password_too_short}, else: :ok
  end

  defp check_password(_password), do: {:error, :password_too_short}

  # conformant_single has exactly one account and it is the server, so a
  # second attempt is an existing server rather than a taken handle.
  #
  # An identifier is a handle or an email, so a string in one column can
  # collide with a string in the other and leave login unable to say which
  # account it means; create_account/3 refuses both directions, and the
  # comparison is exact because that is the one find_by_identifier/1 makes.
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
  # another's email. Ecto refuses to build `== nil` from a pin, so each side
  # is compared only when present; email is NOT NULL on the users table.
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

  # The single account is the server, whose identity was minted at boot, so
  # there is nothing to mint here: the boot-time key is claimed and the
  # operation that registered the DID is carried onto the row. Under the
  # default web identity server_operation/0 is nil, which is the old shape.
  defp claim_account(%{mode: :conformant_single} = identity) do
    with {:ok, key} <- claim_key(identity) do
      {:ok, %{identity: identity, key: key, plc_operation: Identity.server_operation()}}
    end
  end

  # Under PDS_IDENTITY=plc the DID is minted by the directory rather than
  # derived from the hostname, so the key claim and the DID arrive together
  # from Pesque.Plc. Under the default web identity this is exactly the old
  # claim_key/1 with the extra fields left nil.
  defp claim_account(identity) do
    if Pesque.Plc.enabled?() do
      with {:ok, minted} <- Pesque.Plc.mint(identity.handle) do
        {:ok,
         %{
           identity: %{identity | did: minted.did},
           key: minted.key,
           plc_operation: minted.operation
         }}
      end
    else
      with {:ok, key} <- claim_key(identity) do
        {:ok, %{identity: identity, key: key, plc_operation: nil}}
      end
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
  defp insert(identity, email, password, pub_multibase, invite_code, active, plc_operation) do
    result =
      Repo.transaction(fn ->
        with :ok <- consume_invite(invite_code, identity.did),
             {:ok, user} <-
               insert_user(identity, email, password, pub_multibase, active, plc_operation) do
          user
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, user} ->
        Logger.info("account created", did: user.did, handle: user.handle)
        Events.emit_account(user.did, if(active, do: :activated, else: :deactivated))
        {:ok, user}

      {:error, :invalid_invite_code} ->
        Pesque.Plc.Keys.delete(identity.did)
        {:error, :invalid_invite_code}

      {:error, changeset} ->
        Pesque.Plc.Keys.delete(identity.did)

        if email_taken?(changeset) do
          {:error, :email_taken}
        else
          {:error, :missing_fields}
        end
    end
  end

  defp insert_user(identity, email, password_hash, pub_multibase, active, plc_operation) do
    attrs = %{
      did: identity.did,
      handle: identity.handle,
      username: identity.username,
      pubkey_multibase: pub_multibase,
      email: email,
      password_hash: password_hash,
      plc_operation: plc_operation
    }

    changeset = if active, do: User.changeset(attrs), else: User.import_changeset(attrs)
    Repo.insert(changeset)
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

  # alsoKnownAs is taken from the row rather than Did.did_document/2's
  # derivation from the username: updateHandle/2 moves the handle and the DID
  # path it is served at does not move with it. A did:plc account's document
  # is published by the directory, so it is keyed by the stored DID.
  defp document(%User{did: "did:plc:" <> _} = user) do
    Did.plc_document(%{
      did: user.did,
      handle: user.handle,
      pub_multibase: user.pubkey_multibase,
      endpoint: Pesque.service_endpoint()
    })
  end

  defp document(user) do
    Did.did_document(Pesque.mode(), %{
      username: user.username,
      hostname: Pesque.hostname(),
      port: Pesque.port(),
      handle_domain: Pesque.handle_domain(),
      pub_multibase: user.pubkey_multibase,
      endpoint: Pesque.service_endpoint()
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
