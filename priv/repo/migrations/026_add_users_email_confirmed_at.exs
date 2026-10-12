defmodule Pesque.Repo.Migrations.AddUsersEmailConfirmedAt do
  use Ecto.Migration

  # confirmEmail stamps this; NULL means an address that was never confirmed.
  # The column is additive, so every existing row reads as unconfirmed, which
  # is the honest state: nothing here proved those addresses.
  def change do
    alter table(:users) do
      add :email_confirmed_at, :utc_datetime
    end
  end
end
