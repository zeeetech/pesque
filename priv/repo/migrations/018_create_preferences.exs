defmodule Pesque.Repo.Migrations.CreatePreferences do
  use Ecto.Migration

  def change do
    create table(:preferences) do
      add :did, :text, null: false
      add :preferences, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:preferences, [:did])
  end
end
