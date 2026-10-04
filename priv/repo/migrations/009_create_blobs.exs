defmodule Pesque.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add :did, :text, null: false, primary_key: true
      add :cid, :text, null: false, primary_key: true
      add :mime_type, :text, null: false
      add :size, :integer, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end
