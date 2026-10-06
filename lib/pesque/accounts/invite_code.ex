defmodule Pesque.Accounts.InviteCode do
  @moduledoc """
  A code that buys accounts on a server whose registration is closed.

  use_count is how many accounts the code may create and uses is how many it
  has created; the pair is what a conditional claim checks, so a code with two
  uses admits two accounts and no third.

  for_accounts names the DIDs the code may be spent for, or is null for a code
  any account may spend.

  used_by is the DID that last took the code, which is only known once the
  account exists, so the row is claimed before the account is created and the
  DID is written onto it in the same transaction that inserts the account: a
  code a caller failed to spend stays spendable.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "invite_codes" do
    field :code, :string
    field :use_count, :integer, default: 1
    field :uses, :integer, default: 0
    field :for_accounts, {:array, :string}
    field :used_by, :string
    field :used_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:code, :use_count, :uses, :for_accounts, :used_by, :used_at])
    |> validate_required([:code, :use_count, :uses])
    |> validate_number(:use_count, greater_than: 0)
    |> unique_constraint(:code)
  end
end
