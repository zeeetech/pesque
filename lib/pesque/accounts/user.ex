defmodule Pesque.Accounts.User do
  @moduledoc "The single local account: server DID, handle, email, Argon2id password hash."

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :did, :string
    field :handle, :string
    field :email, :string
    field :password_hash, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:did, :handle, :email, :password_hash])
    |> validate_required([:did, :handle, :email, :password_hash])
    |> unique_constraint(:did)
    |> unique_constraint(:handle)
  end
end
