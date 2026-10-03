defmodule Pesque.Accounts.User do
  @moduledoc """
  A local account: DID, handle, and the key it signs commits with.

  username and pubkey_multibase are NULL under conformant_single, which has
  no path to resolve and whose single account signs with the server key.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :did, :string
    field :handle, :string
    field :username, :string
    field :pubkey_multibase, :string
    field :email, :string
    field :password_hash, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:did, :handle, :username, :pubkey_multibase, :email, :password_hash])
    |> validate_required([:did, :handle, :email, :password_hash])
    |> unique_constraint(:did)
    |> unique_constraint(:handle)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end
end
