defmodule Pesque.Repo.Migrations.AddOauthRequestsGrantedScope do
  use Ecto.Migration

  # What the account holder actually granted, next to the scope the client
  # asked for. The requested scope is never mutated: it is the client's
  # record of the flow, and the granted one is the account holder's answer to
  # it. Nil until a decision is made, so a row approved by an older build
  # falls back to the requested scope at exchange time and the deploy is
  # order-free.
  def change do
    alter table(:oauth_requests) do
      add :granted_scope, :text
    end
  end
end
