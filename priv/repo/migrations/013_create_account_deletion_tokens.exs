defmodule Pesque.Repo.Migrations.CreateAccountDeletionTokens do
  use Ecto.Migration

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
