defmodule Pesque.Repo.Migrations.CreateMigrationJobs do
  use Ecto.Migration

  # One row per move that runs off-request, and the state a page watching the
  # move reads. The row carries no credential: the old account's password
  # never leaves the worker process, and the PLC code is handed to that
  # process directly rather than written down. `token` is the whole
  # capability, so the unique index is on it.

  def change do
    create table(:migration_jobs) do
      add :token, :text, null: false
      add :handle, :text, null: false
      add :old_pds, :text, null: false
      add :phase, :text, null: false
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:migration_jobs, [:token])
  end
end
