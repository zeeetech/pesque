defmodule Pesque.Accounts.EmailToken do
  @moduledoc """
  A one-time, expiring code bound to an email address that proves control of
  it. One primitive serves both email flows: `confirmEmail` spends it to stamp
  the address confirmed, and `updateEmail` spends it (when the current address
  is confirmed) before moving the account to a new one.

  The spec delivers this code by email to the account holder; there is no mail
  here, so it reaches the operator through the log and the CLI instead (see
  `Pesque.Accounts.request_email_confirmation/1` and
  `Pesque.Accounts.request_email_update/1`). Only the hash is kept, so a row
  lifted out of this table is not a code that confirms or moves anything.

  used_at is what makes it single use: it is written by the same conditional
  update that spends it, so two callers racing with one code produce one effect
  and one refusal. The email is stored beside the DID, so a code is bound to
  the address it was minted for.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "email_tokens" do
    field :token_hash, :string
    field :did, :string
    field :email, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:token_hash, :did, :email, :expires_at, :used_at])
    |> validate_required([:token_hash, :did, :email, :expires_at])
    |> unique_constraint(:token_hash)
  end

  def hash_token(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
