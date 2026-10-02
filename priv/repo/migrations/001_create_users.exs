defmodule Pesque.Repo.Migrations.CreateUsers do
  use Ecto.Migration

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
