defmodule Pesque.Repo.Migrations.CreateBlockOwnership do
  use Ecto.Migration

  def change do
    create table(:blocks_v2, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :cid, :text, null: false, primary_key: true
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    execute(
      "INSERT INTO blocks_v2 (did, cid, data, inserted_at) SELECT did, cid, data, inserted_at FROM blocks"
    )

    drop index(:blocks, [:did])
    drop table(:blocks)

    rename table(:blocks_v2), to: table(:blocks)
  end
end
