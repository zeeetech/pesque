defmodule Pesque.Accounts.AppPassword do
  @moduledoc """
  A named, revocable credential an account's apps log in with, weaker than
  the account password.

  Only the hash is kept. It is sha256 over the did and the password together,
  so it is deterministic (login is one indexed equality lookup, the same
  construction a refresh jti uses) and account-scoped (a password string can
  never match another account's rows). Argon2 would buy nothing here: the
  password is a server-generated 80-bit secret, the same entropy class as a
  refresh jti, and a per-row verify would forbid the indexed lookup.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "app_passwords" do
    field :did, :string
    field :name, :string
    field :password_hash, :string
    field :privileged, :boolean, default: false

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:did, :name, :password_hash, :privileged])
    |> validate_required([:did, :name, :password_hash])
    |> unique_constraint([:did, :name])
    |> unique_constraint([:did, :password_hash])
  end

  def hash_password(did, password) when is_binary(did) and is_binary(password),
    do: Base.encode16(:crypto.hash(:sha256, did <> ":" <> password), case: :lower)
end
