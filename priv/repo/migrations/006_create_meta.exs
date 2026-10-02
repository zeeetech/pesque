defmodule Pesque.Repo.Migrations.CreateMeta do
  use Ecto.Migration

  def change do
    create table(:meta, primary_key: false) do
      add :key, :text, null: false, primary_key: true
      add :value, :text, null: false
    end
  end
end