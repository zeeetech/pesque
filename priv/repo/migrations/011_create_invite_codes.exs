defmodule Pesque.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

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
