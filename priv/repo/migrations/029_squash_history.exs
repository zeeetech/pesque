defmodule Pesque.Repo.Migrations.CreateUsers do
  import Ecto.Migration

  def change do
    create table(:users) do
      add :did, :text, null: false
      add :handle, :text, null: false
      add :email, :text, null: false
      add :password_hash, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:did])
    create unique_index(:users, [:handle])
  end
end

defmodule Pesque.Repo.Migrations.CreateRefreshTokens do
  import Ecto.Migration

  def change do
    create table(:refresh_tokens) do
      add :jti_hash, :text, null: false
      add :did, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :revoked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:refresh_tokens, [:jti_hash])
  end
end

defmodule Pesque.Repo.Migrations.CreateRecords do
  import Ecto.Migration

  def change do
    create table(:records, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :collection, :text, null: false, primary_key: true
      add :rkey, :text, null: false, primary_key: true
      add :cid, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:records, [:did, :collection])
  end
end

defmodule Pesque.Repo.Migrations.CreateBlocks do
  import Ecto.Migration

  def change do
    create table(:blocks, primary_key: false) do
      add :cid, :text, null: false, primary_key: true
      add :did, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:blocks, [:did])
  end
end

defmodule Pesque.Repo.Migrations.CreateEvents do
  import Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :seq, :integer, null: false, primary_key: true
      add :did, :text, null: false
      add :payload, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateMeta do
  import Ecto.Migration

  def change do
    create table(:meta, primary_key: false) do
      add :key, :text, null: false, primary_key: true
      add :value, :text, null: false
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateBlockOwnership do
  import Ecto.Migration

  # Reversible now: the old table is rebuilt in down/0 from the data that was
  # copied into blocks_v2, so rollback loses no rows. A cid owned by several
  # accounts (possible only after the up migration loosened the key) comes
  # back owned by an arbitrary one, matching the old single-owner shape.
  def up do
    create table(:blocks_v2, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :cid, :text, null: false, primary_key: true
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    execute(
      "INSERT INTO blocks_v2 (did, cid, data, inserted_at) SELECT did, cid, data, inserted_at FROM blocks"
    )

    drop index(:blocks, [:did])
    drop table(:blocks)

    rename table(:blocks_v2), to: table(:blocks)
  end

  def down do
    rename table(:blocks), to: table(:blocks_v2)

    create table(:blocks, primary_key: false) do
      add :cid, :text, null: false, primary_key: true
      add :did, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    execute(
      "INSERT INTO blocks (cid, did, data, inserted_at) SELECT cid, did, data, inserted_at FROM blocks_v2 GROUP BY cid"
    )

    create index(:blocks, [:did])

    drop table(:blocks_v2)
  end
end

defmodule Pesque.Repo.Migrations.AddAccountKeys do
  import Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :text
      add :pubkey_multibase, :text
    end

    # username is NULL under single, where there is no path to
    # resolve, so the index is partial to keep the single row out of it.
    create unique_index(:users, [:username],
             where: "username IS NOT NULL",
             name: :users_username_index
           )

    # verify_login matches handle OR email in one query, so an email equal to
    # another account's handle returns two rows and raises.
    create unique_index(:users, [:email])
  end
end

defmodule Pesque.Repo.Migrations.CreateBlobs do
  import Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :cid, :text, null: false, primary_key: true
      add :mime_type, :text, null: false
      add :size, :integer, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end

defmodule Pesque.Repo.Migrations.AddRefreshTokensDidIndex do
  import Ecto.Migration

  # 002 left refresh_tokens without an index on did, and session lookups go
  # through it, so the index lands here rather than by editing 002: these
  # migrations may already have run against a live data directory, and a
  # later edit to 002 would silently skip them there. Same reason 003 is
  # edited here rather than in place.
  def change do
    create index(:refresh_tokens, [:did])

    # Redundant with the (did, collection, rkey) primary key, which answers
    # the same (did, collection) prefix lookups.
    drop index(:records, [:did, :collection])

    # 004's blocks (did) index would be redundant with the (did, cid) primary
    # key 007 created; 007 already dropped it, so nothing to do. Noted here so
    # the next reader does not re-derive the same conclusion from 004.
  end
end

defmodule Pesque.Repo.Migrations.CreateInviteCodes do
  import Ecto.Migration

  def change do
    create table(:invite_codes) do
      add :code, :text, null: false
      add :used_by, :text
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:invite_codes, [:code])
  end
end

defmodule Pesque.Repo.Migrations.InviteCodeLimits do
  import Ecto.Migration

  # 011 gave every code exactly one use and no owner restriction. Both are
  # lexicon inputs on createInviteCodes, so they land here rather than by
  # editing 011: these migrations may already have run against a live data
  # directory, and a later edit to 011 would silently skip them there.
  #
  # for_accounts is null rather than empty on purpose. An empty JSON array and
  # NULL would both mean "no restriction", and one representation for that is
  # one thing the claim query has to answer.
  def change do
    alter table(:invite_codes) do
      add :use_count, :integer, null: false, default: 1
      add :uses, :integer, null: false, default: 0
      add :for_accounts, {:array, :string}
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateAccountDeletionTokens do
  import Ecto.Migration

  # deleteAccount is a two-step flow in the spec: requestAccountDelete hands out
  # a token, and deleteAccount spends it with the account password. The token
  # has to be server-side state because it is single use and expiring, neither
  # of which anything signed could carry on its own.
  #
  # The token is stored hashed, like a refresh jti: a row read out of this
  # table must not be enough to delete an account.
  def change do
    create table(:account_deletion_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_deletion_tokens, [:token_hash])
    create index(:account_deletion_tokens, [:did])
  end
end

defmodule Pesque.Repo.Migrations.AddAccountActive do
  import Ecto.Migration

  # Deactivation is not the absence of a repo: the rows, the blocks and the key
  # all stay, and activateAccount puts them back. So the state needs a column
  # of its own, and it defaults to true because every account that existed
  # before this migration was active by definition.
  def change do
    alter table(:users) do
      add :active, :boolean, null: false, default: true
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateOauth do
  import Ecto.Migration

  # The atproto OAuth profile is a four-part flow and three of the four parts
  # are server-side state a signed token cannot carry on its own: a pushed
  # authorization request has to survive the redirect to the login page, a code
  # has to be single use, and a refresh token has to be rotatable and
  # revocable. So the requests, the tokens and the DPoP nonce are rows.
  #
  # Nothing here is stored in the clear. A request_uri, a code and a refresh
  # token are all bearer credentials, so each is kept as the SHA-256 of the
  # value and looked up by that hash, the way a refresh jti and a deletion
  # token already are. A row lifted out of this table must not be enough to
  # finish somebody else's flow.
  def change do
    create table(:oauth_requests) do
      add :request_uri_hash, :text, null: false
      add :client_id, :text, null: false
      add :redirect_uri, :text, null: false
      add :state, :text, null: false
      add :scope, :text, null: false
      add :code_challenge, :text, null: false
      add :code_challenge_method, :text, null: false
      add :login_hint, :text
      add :dpop_jkt, :text, null: false
      add :did, :text
      add :code_hash, :text
      add :code_expires_at, :utc_datetime
      add :used_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_requests, [:request_uri_hash])
    create unique_index(:oauth_requests, [:code_hash])

    create table(:oauth_tokens) do
      add :token_hash, :text, null: false
      add :jti, :text, null: false
      add :kind, :text, null: false
      add :did, :text, null: false
      add :client_id, :text, null: false
      add :scope, :text, null: false
      add :dpop_jkt, :text, null: false
      add :session_id, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_tokens, [:token_hash])
    create unique_index(:oauth_tokens, [:jti])
    create index(:oauth_tokens, [:session_id])
    create index(:oauth_tokens, [:did])

    # One live nonce for the whole server, which the spec allows: it exists to
    # bind a proof to this server, not to a session. Rotating it replaces the
    # row rather than adding one, and the row it replaces is kept in `previous`
    # so a request already in flight with the old nonce still verifies.
    create table(:oauth_dpop_nonces) do
      add :nonce, :text, null: false
      add :previous, :text
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_dpop_nonces, [:nonce])
  end
end

defmodule Pesque.Repo.Migrations.AddPlcOperation do
  import Ecto.Migration

  # The signed genesis (or most recent) PLC operation for a did:plc account,
  # as JSON. It is what the next handle change points its `prev` at. It is
  # NULL for every did:web account, which has no operation log, so the column
  # is additive and the default behaviour is unchanged.
  def change do
    alter table(:users) do
      add :plc_operation, :text
    end
  end
end

defmodule Pesque.Repo.Migrations.DropOauthDpopNonces do
  import Ecto.Migration

  # The DPoP nonce is now held in :persistent_term rather than a row. It is
  # server-wide and needs no durability: a restart minting a fresh one is fine
  # because a client retries on use_dpop_nonce, and the `previous` grace lives
  # in the term now. Nothing reads or writes this table.
  def change do
    drop table(:oauth_dpop_nonces)
  end
end

defmodule Pesque.Repo.Migrations.CreatePreferences do
  import Ecto.Migration

  def change do
    create table(:preferences) do
      add :did, :text, null: false
      add :preferences, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:preferences, [:did])
  end
end

defmodule Pesque.Repo.Migrations.AddUsersDeactivatedAt do
  import Ecto.Migration

  # account list shows when an account was deactivated, which the active
  # boolean alone cannot answer. deactivate_account stamps it and
  # activate_account clears it; every account that existed before this
  # migration was active by definition, so the column starts null.
  def change do
    alter table(:users) do
      add :deactivated_at, :utc_datetime
    end
  end
end

defmodule Pesque.Repo.Migrations.CreatePlcOperationTokens do
  import Ecto.Migration

  # signPlcOperation is a two-step flow, like deleteAccount:
  # requestPlcOperationSignature hands out a code and signPlcOperation spends
  # it. The code has to be server-side state because it is single use and
  # expiring, neither of which anything signed could carry on its own. The
  # spec delivers it by email; there is no mail here, so it reaches the
  # operator through the log and the CLI instead.
  #
  # The code is stored hashed, like the deletion token and a refresh jti: a
  # row read out of this table must not be enough to move an identity.
  def change do
    create table(:plc_operation_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:plc_operation_tokens, [:token_hash])
    create index(:plc_operation_tokens, [:did])
  end
end

defmodule Pesque.Repo.Migrations.AddOauthRequestsGrantedScope do
  import Ecto.Migration

  # What the account holder actually granted, next to the scope the client
  # asked for. The requested scope is never mutated: it is the client's
  # record of the flow, and the granted one is the account holder's answer to
  # it. Nil until a decision is made, so a row approved by an older build
  # falls back to the requested scope at exchange time and the deploy is
  # order-free.
  def change do
    alter table(:oauth_requests) do
      add :granted_scope, :text
    end
  end
end

defmodule Pesque.Repo.Migrations.AddOauthTokensGrants do
  import Ecto.Migration

  # What this token actually carries, as the canonical scope strings of the
  # expansion it was issued with. Written on the access row only: the refresh
  # row is spent at use and recomputes the expansion then, so its grants are
  # nil. Nil on rows an older build wrote, and the scope string is what those
  # tokens' grants are computed from, which is why nothing is backfilled.
  def change do
    alter table(:oauth_tokens) do
      add :grants, :text
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateAppPasswords do
  import Ecto.Migration

  # A named credential an account's apps log in with, weaker than the
  # password. Only the hash is kept, like a refresh jti: a row lifted out of
  # this table is not a live credential. The hash is keyed to the account
  # (did <> ":" <> password), so a password string can only ever match the
  # account it was made for, and login is one indexed lookup instead of a
  # walk over argon2 hashes.
  #
  # refresh_tokens gains the name of the app password the session was opened
  # with: the refresh row is what ties a live session to the credential, so
  # rotating re-reads the credential's privilege and revoking it kills the
  # session in the same transaction the row goes.
  def change do
    create table(:app_passwords) do
      add :did, :text, null: false
      add :name, :text, null: false
      add :password_hash, :text, null: false
      add :privileged, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:app_passwords, [:did, :name])
    create unique_index(:app_passwords, [:did, :password_hash])

    alter table(:refresh_tokens) do
      add :app_password_name, :text
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateEmailTokens do
  import Ecto.Migration

  # The two email flows are two-step and share one primitive: a code bound to
  # an address that proves control of it. confirmEmail spends it to stamp the
  # address confirmed; updateEmail spends it (when the current address is
  # confirmed) before moving the account to a new one. requestEmailConfirmation
  # and requestEmailUpdate both mint into this table.
  #
  # The code has to be server-side state because it is single use and expiring,
  # neither of which anything signed could carry on its own. The spec delivers
  # it by email; there is no mail here, so it reaches the operator through the
  # log and the CLI instead.
  #
  # The code is stored hashed, like the deletion and plc operation tokens: a
  # row read out of this table must not be enough to move or confirm an
  # address. The email sits beside the DID so a code for one address cannot
  # stand for another.
  def change do
    create table(:email_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :email, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:email_tokens, [:token_hash])
    create index(:email_tokens, [:did])
  end
end

defmodule Pesque.Repo.Migrations.CreatePasswordResetTokens do
  import Ecto.Migration

  # resetPassword is a two-step flow: requestPasswordReset hands out a code and
  # resetPassword spends it. Unlike deleteAccount the requester is anonymous, so
  # the code is never answered to the caller: it is stored hashed, logged, and
  # mintable through the CLI, the way the plc operation token is.
  #
  # The code is stored hashed, like the deletion and plc operation tokens: a
  # row read out of this table must not be enough to reset a password.
  def change do
    create table(:password_reset_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:password_reset_tokens, [:token_hash])
    create index(:password_reset_tokens, [:did])
  end
end

defmodule Pesque.Repo.Migrations.AddUsersEmailConfirmedAt do
  import Ecto.Migration

  # confirmEmail stamps this; NULL means an address that was never confirmed.
  # The column is additive, so every existing row reads as unconfirmed, which
  # is the honest state: nothing here proved those addresses.
  def change do
    alter table(:users) do
      add :email_confirmed_at, :utc_datetime
    end
  end
end

defmodule Pesque.Repo.Migrations.ConsolidateAccountTokens do
  import Ecto.Migration

  # One table for the single-use codes an account flow hands out. The four
  # tables this replaces were the same three-column shape under four names, so
  # this copies any live rows into one table with a `purpose` that tells the
  # flows apart, then drops the rest.
  #
  # `purpose` is what keeps a code minted for one flow from being spent by
  # another: without it a deletion code and a password reset code would be
  # indistinguishable, since both are bound to a DID and an expiry.
  #
  # The two older tables shipped, so their rows are copied. The two newer ones
  # never shipped, so they are dropped if a development database happens to
  # carry them.

  @moved %{
    "plc_operation_tokens" => "plc_operation",
    "account_deletion_tokens" => "account_delete",
    "email_tokens" => "email",
    "password_reset_tokens" => "reset_password"
  }

  def up do
    create table(:account_tokens) do
      add :token_hash, :text, null: false
      add :purpose, :text, null: false
      add :did, :text, null: false
      add :email, :text
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_tokens, [:token_hash])
    create index(:account_tokens, [:did])

    for {table, purpose} <- @moved, table_exists?(table) do
      copy_rows(table, purpose)
      drop table(table)
    end
  end

  def down do
    raise Ecto.MigrationError,
          "consolidate_account_tokens is not reversible; the four tables it " <>
            "replaces would come back empty"
  end

  defp copy_rows(table, purpose) do
    execute("""
    INSERT INTO account_tokens (token_hash, purpose, did, email, expires_at, used_at, inserted_at)
    SELECT token_hash, '#{purpose}', did, #{email_column(table)}, expires_at, used_at, inserted_at
    FROM #{table}
    """)
  end

  defp email_column("email_tokens"), do: "email"
  defp email_column(_table), do: "NULL"

  # The old tables were committed by earlier migrations, so they are visible to
  # a query even while this migration holds its own transaction open.
  defp table_exists?(table) do
    case repo().query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end
end

defmodule Pesque.Repo.Migrations.CreateMigrationJobs do
  import Ecto.Migration

  # One row per move that runs off-request, and the state a page watching the
  # move reads. The row carries no credential: the old account's password
  # never leaves the worker process, and the PLC code is handed to that
  # process directly rather than written down. `token` is the whole
  # capability, so the unique index is on it.

  def change do
    create table(:migration_jobs) do
      add :token, :text, null: false
      add :handle, :text, null: false
      add :old_pds, :text, null: false
      add :phase, :text, null: false
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:migration_jobs, [:token])
  end
end

defmodule Pesque.Repo.Migrations.SquashHistory do
  use Ecto.Migration

  @legacy_migrations [
    {1, Pesque.Repo.Migrations.CreateUsers, :change},
    {2, Pesque.Repo.Migrations.CreateRefreshTokens, :change},
    {3, Pesque.Repo.Migrations.CreateRecords, :change},
    {4, Pesque.Repo.Migrations.CreateBlocks, :change},
    {5, Pesque.Repo.Migrations.CreateEvents, :change},
    {6, Pesque.Repo.Migrations.CreateMeta, :change},
    {7, Pesque.Repo.Migrations.CreateBlockOwnership, :up},
    {8, Pesque.Repo.Migrations.AddAccountKeys, :change},
    {9, Pesque.Repo.Migrations.CreateBlobs, :change},
    {10, Pesque.Repo.Migrations.AddRefreshTokensDidIndex, :change},
    {11, Pesque.Repo.Migrations.CreateInviteCodes, :change},
    {12, Pesque.Repo.Migrations.InviteCodeLimits, :change},
    {13, Pesque.Repo.Migrations.CreateAccountDeletionTokens, :change},
    {14, Pesque.Repo.Migrations.AddAccountActive, :change},
    {15, Pesque.Repo.Migrations.CreateOauth, :change},
    {16, Pesque.Repo.Migrations.AddPlcOperation, :change},
    {17, Pesque.Repo.Migrations.DropOauthDpopNonces, :change},
    {18, Pesque.Repo.Migrations.CreatePreferences, :change},
    {19, Pesque.Repo.Migrations.AddUsersDeactivatedAt, :change},
    {20, Pesque.Repo.Migrations.CreatePlcOperationTokens, :change},
    {21, Pesque.Repo.Migrations.AddOauthRequestsGrantedScope, :change},
    {22, Pesque.Repo.Migrations.AddOauthTokensGrants, :change},
    {23, Pesque.Repo.Migrations.CreateAppPasswords, :change},
    {24, Pesque.Repo.Migrations.CreateEmailTokens, :change},
    {25, Pesque.Repo.Migrations.CreatePasswordResetTokens, :change},
    {26, Pesque.Repo.Migrations.AddUsersEmailConfirmedAt, :change},
    {27, Pesque.Repo.Migrations.ConsolidateAccountTokens, :up},
    {28, Pesque.Repo.Migrations.CreateMigrationJobs, :change}
  ]

  def up do
    versions = migrated_versions()

    cond do
      MapSet.size(versions) == 0 and application_tables?() ->
        raise Ecto.MigrationError,
              "database has Pesque tables but no migration history; refusing to overwrite it"

      Enum.any?(versions, &(&1 > 28)) ->
        raise Ecto.MigrationError,
              "database migration history is newer than the supported pre-squash history"

      true ->
        Enum.each(@legacy_migrations, fn {version, module, function} ->
          unless MapSet.member?(versions, version), do: apply(module, function, [])
        end)

        unless MapSet.member?(versions, 27), do: drop_new_legacy_token_tables()
    end
  end

  def down do
    raise Ecto.MigrationError,
          "squashed migrations cannot be rolled back; restore the pre-upgrade backup"
  end

  defp migrated_versions do
    repo().query!("SELECT version FROM schema_migrations").rows
    |> Enum.map(fn [version] -> version end)
    |> MapSet.new()
  end

  defp application_tables? do
    case repo().query!("""
         SELECT name FROM sqlite_master
         WHERE type = 'table'
           AND name NOT LIKE 'sqlite_%'
           AND name != 'schema_migrations'
         LIMIT 1
         """).rows do
      [] -> false
      _rows -> true
    end
  end

  defp drop_new_legacy_token_tables do
    for table <- [
          "plc_operation_tokens",
          "account_deletion_tokens",
          "email_tokens",
          "password_reset_tokens"
        ] do
      execute("DROP TABLE IF EXISTS #{table}")
    end
  end
end
