defmodule Pesque.Repo.Migrations.InviteCodeLimits do
  use Ecto.Migration

  # 011 gave every code exactly one use and no owner restriction. Both are
  # lexicon inputs on createInviteCodes, so they land here rather than by
  # editing 011: these migrations may already have run against a live data
  # directory, and a later edit to 011 would silently skip them there.
  #
  # for_accounts is null rather than empty on purpose. An empty JSON array and
  # NULL would both mean "no restriction", and one representation for that is
  # one thing the claim query has to answer.
  def change do
    alter table(:invite_codes) do
      add :use_count, :integer, null: false, default: 1
      add :uses, :integer, null: false, default: 0
      add :for_accounts, {:array, :string}
    end
  end
end
