defmodule Pesque.Repo.Migrations.AddUsersDeactivatedAt do
  use Ecto.Migration

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
