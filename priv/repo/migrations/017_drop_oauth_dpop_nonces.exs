defmodule Pesque.Repo.Migrations.DropOauthDpopNonces do
  use Ecto.Migration

  # The DPoP nonce is now held in :persistent_term rather than a row. It is
  # server-wide and needs no durability: a restart minting a fresh one is fine
  # because a client retries on use_dpop_nonce, and the `previous` grace lives
  # in the term now. Nothing reads or writes this table.
  def change do
    drop table(:oauth_dpop_nonces)
  end
end
