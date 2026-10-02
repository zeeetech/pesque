defmodule Pesque.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks, primary_key: false) do
      add :cid, :text, null: false, primary_key: true
      add :did, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:blocks, [:did])
  end
end