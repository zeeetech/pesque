defmodule Pesque.Repo.Migrations.AddAccountKeys do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :username, :text
      add :pubkey_multibase, :text
    end

    # username is NULL under conformant_single, where there is no path to
    # resolve, so the index is partial to keep the single row out of it.
    create unique_index(:users, [:username],
             where: "username IS NOT NULL",
             name: :users_username_index
           )

    # verify_login matches handle OR email in one query, so an email equal to
    # another account's handle returns two rows and raises.
    create unique_index(:users, [:email])
  end
end