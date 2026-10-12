defmodule Pesque.Repo.Migrations.ConsolidateAccountTokens do
  use Ecto.Migration

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
