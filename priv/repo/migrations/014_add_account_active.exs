defmodule Pesque.Repo.Migrations.AddAccountActive do
  use Ecto.Migration

  # Deactivation is not the absence of a repo: the rows, the blocks and the key
  # all stay, and activateAccount puts them back. So the state needs a column
  # of its own, and it defaults to true because every account that existed
  # before this migration was active by definition.
  def change do
    alter table(:users) do
      add :active, :boolean, null: false, default: true
    end
  end
end
