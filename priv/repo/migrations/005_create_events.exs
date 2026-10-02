defmodule Pesque.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :seq, :integer, null: false, primary_key: true
      add :did, :text, null: false
      add :payload, :blob, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end