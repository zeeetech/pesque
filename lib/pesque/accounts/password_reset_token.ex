defmodule Pesque.Accounts.PasswordResetToken do
  @moduledoc """
  A one-time, expiring token that authorizes resetting an account's password.

  The spec delivers this code by email to the account holder; there is no mail
  here, so it reaches the operator through the log and the CLI instead (see
  `Pesque.Accounts.request_password_reset/1`). The requester is anonymous, so
  the code is never answered to the caller: only its hash is kept, and a row
  read out of this table must not be enough to reset a password.

  used_at is what makes it single use: it is written by the same conditional
  update that spends it, so two callers racing with one code produce one reset
  and one refusal.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "password_reset_tokens" do
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
