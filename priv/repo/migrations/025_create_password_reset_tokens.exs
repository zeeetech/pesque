defmodule Pesque.Repo.Migrations.CreatePasswordResetTokens do
  use Ecto.Migration

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
