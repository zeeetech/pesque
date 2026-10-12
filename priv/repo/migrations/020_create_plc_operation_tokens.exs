defmodule Pesque.Repo.Migrations.CreatePlcOperationTokens do
  use Ecto.Migration

  # signPlcOperation is a two-step flow, like deleteAccount:
  # requestPlcOperationSignature hands out a code and signPlcOperation spends
  # it. The code has to be server-side state because it is single use and
  # expiring, neither of which anything signed could carry on its own. The
  # spec delivers it by email; there is no mail here, so it reaches the
  # operator through the log and the CLI instead.
  #
  # The code is stored hashed, like the deletion token and a refresh jti: a
  # row read out of this table must not be enough to move an identity.
  def change do
    create table(:plc_operation_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:plc_operation_tokens, [:token_hash])
    create index(:plc_operation_tokens, [:did])
  end
end
