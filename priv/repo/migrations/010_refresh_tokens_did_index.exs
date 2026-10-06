defmodule Pesque.Repo.Migrations.AddRefreshTokensDidIndex do
  use Ecto.Migration

  # 002 left refresh_tokens without an index on did, and session lookups go
  # through it, so the index lands here rather than by editing 002: these
  # migrations may already have run against a live data directory, and a
  # later edit to 002 would silently skip them there. Same reason 003 is
  # edited here rather than in place.
  def change do
    create index(:refresh_tokens, [:did])

    # Redundant with the (did, collection, rkey) primary key, which answers
    # the same (did, collection) prefix lookups.
    drop index(:records, [:did, :collection])

    # 004's blocks (did) index would be redundant with the (did, cid) primary
    # key 007 created; 007 already dropped it, so nothing to do. Noted here so
    # the next reader does not re-derive the same conclusion from 004.
  end
end
