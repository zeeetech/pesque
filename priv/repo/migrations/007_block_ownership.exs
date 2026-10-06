defmodule Pesque.Repo.Migrations.CreateBlockOwnership do
  use Ecto.Migration

  # Reversible now: the old table is rebuilt in down/0 from the data that was
  # copied into blocks_v2, so rollback loses no rows. A cid owned by several
  # accounts (possible only after the up migration loosened the key) comes
  # back owned by an arbitrary one, matching the old single-owner shape.
  def up do
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

  def down do
    rename table(:blocks), to: table(:blocks_v2)

    create table(:blocks, primary_key: false) do
      add :cid, :text, null: false, primary_key: true
      add :did, :text, null: false
      add :data, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    execute(
      "INSERT INTO blocks (cid, did, data, inserted_at) SELECT cid, did, data, inserted_at FROM blocks_v2 GROUP BY cid"
    )

    create index(:blocks, [:did])

    drop table(:blocks_v2)
  end
end
