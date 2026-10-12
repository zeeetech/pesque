defmodule Pesque.Repo.Migrations.CreateEmailTokens do
  use Ecto.Migration

  # The two email flows are two-step and share one primitive: a code bound to
  # an address that proves control of it. confirmEmail spends it to stamp the
  # address confirmed; updateEmail spends it (when the current address is
  # confirmed) before moving the account to a new one. requestEmailConfirmation
  # and requestEmailUpdate both mint into this table.
  #
  # The code has to be server-side state because it is single use and expiring,
  # neither of which anything signed could carry on its own. The spec delivers
  # it by email; there is no mail here, so it reaches the operator through the
  # log and the CLI instead.
  #
  # The code is stored hashed, like the deletion and plc operation tokens: a
  # row read out of this table must not be enough to move or confirm an
  # address. The email sits beside the DID so a code for one address cannot
  # stand for another.
  def change do
    create table(:email_tokens) do
      add :token_hash, :text, null: false
      add :did, :text, null: false
      add :email, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:email_tokens, [:token_hash])
    create index(:email_tokens, [:did])
  end
end
