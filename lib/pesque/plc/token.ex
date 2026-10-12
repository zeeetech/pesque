defmodule Pesque.Plc.Token do
  @moduledoc """
  A one-time, expiring token that authorizes signing a PLC operation.

  The spec delivers this code by email to the account holder; there is no
  mail here, so it reaches the operator through the log and the CLI instead
  (see `Pesque.Plc.request_operation_signature/1`). What a token is once
  issued is exactly what the deletion token is: only its hash is kept, and
  used_at is what makes it single use, written by the same conditional
  update that spends it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "plc_operation_tokens" do
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
