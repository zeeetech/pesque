defmodule Pesque.Repo.Migrations.CreateRefreshTokens do
  use Ecto.Migration

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
