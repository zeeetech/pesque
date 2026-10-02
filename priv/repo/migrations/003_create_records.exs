defmodule Pesque.Repo.Migrations.CreateRecords do
  use Ecto.Migration

  def change do
    create table(:records, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :collection, :text, null: false, primary_key: true
      add :rkey, :text, null: false, primary_key: true
      add :cid, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:records, [:did, :collection])
  end
end