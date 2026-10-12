defmodule Pesque.Repo.Migrations.AddOauthTokensGrants do
  use Ecto.Migration

  # What this token actually carries, as the canonical scope strings of the
  # expansion it was issued with. Written on the access row only: the refresh
  # row is spent at use and recomputes the expansion then, so its grants are
  # nil. Nil on rows an older build wrote, and the scope string is what those
  # tokens' grants are computed from, which is why nothing is backfilled.
  def change do
    alter table(:oauth_tokens) do
      add :grants, :text
    end
  end
end
