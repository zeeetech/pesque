defmodule Pesque.Repo.Migrations.CreateAppPasswords do
  use Ecto.Migration

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
