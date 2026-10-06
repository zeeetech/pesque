defmodule Pesque.Repo.Migrations.AddPlcOperation do
  use Ecto.Migration

  # The signed genesis (or most recent) PLC operation for a did:plc account,
  # as JSON. It is what the next handle change points its `prev` at. It is
  # NULL for every did:web account, which has no operation log, so the column
  # is additive and the default behaviour is unchanged.
  def change do
    alter table(:users) do
      add :plc_operation, :text
    end
  end
end
