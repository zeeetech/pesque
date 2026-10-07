defmodule Pesque.Accounts.RefreshToken do
  @moduledoc "Server-side record of a live refresh token, keyed by the hash of its jti."

  use Ecto.Schema

  import Ecto.Changeset

  schema "refresh_tokens" do
    field :jti_hash, :string
    field :did, :string
    field :expires_at, :utc_datetime
    field :revoked, :boolean, default: false

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:jti_hash, :did, :expires_at, :revoked])
    |> validate_required([:jti_hash, :did, :expires_at])
    |> unique_constraint(:jti_hash)
  end

  def hash_jti(jti), do: Base.encode16(:crypto.hash(:sha256, jti), case: :lower)
end
