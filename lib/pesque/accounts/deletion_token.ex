defmodule Pesque.Accounts.DeletionToken do
  @moduledoc """
  A one-time, expiring token that authorizes deleting an account.

  Only the hash of the token is kept: a row lifted out of this table must not
  be enough to destroy an account, so the check is a hash comparison and not a
  string comparison.

  used_at is what makes it single use. It is written by the same conditional
  update that spends it, so two callers racing with one token produce one
  deletion and one refusal.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "account_deletion_tokens" do
    field :token_hash, :string
    field :did, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:token_hash, :did, :expires_at, :used_at])
    |> validate_required([:token_hash, :did, :expires_at])
    |> unique_constraint(:token_hash)
  end

  def hash_token(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
