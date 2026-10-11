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

    # The signed PLC operation for a did:plc account. NULL for every did:web
    # account, which has no operation log.
    field :plc_operation, :string

    # Not cast by changeset/1: whether an account is deactivated is not
    # something a create request decides, and the only way to move it is
    # deactivate_account/activate_account, which stamps (and clears) the
    # time it happened.
    field :active, :boolean, default: true
    field :deactivated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :did,
      :handle,
      :username,
      :pubkey_multibase,
      :email,
      :password_hash,
      :plc_operation
    ])
    |> validate_required([:did, :handle, :email, :password_hash])
    |> unique_constraint(:did)
    |> unique_constraint(:handle)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end

  # An imported account starts deactivated: the DID is being moved here and the
  # repo is empty until importRepo fills it, so nothing should be served or
  # written until activateAccount says the move is done.
  def import_changeset(attrs) do
    attrs |> changeset() |> put_change(:active, false)
  end

  # The operation a migrating account submitted, recorded after the PLC
  # directory accepted it. It is the `prev` the next handle change points at,
  # so it is only written once the network agrees with it.
  def plc_operation_changeset(%__MODULE__{} = row, operation) do
    change(row, plc_operation: operation)
  end

  def handle_changeset(%__MODULE__{} = row, overrides) do
    row
    |> change(overrides)
    |> validate_required([:handle])
    |> unique_constraint(:handle)
  end

  # Moving active also moves deactivated_at: the timestamp is the answer to
  # "since when", so activating clears it rather than leaving a time the
  # account was no longer deactivated for. The clear is forced, not compared:
  # a caller holding the row from before the deactivation would otherwise
  # compare nil against nil and leave the old time standing.
  def active_changeset(%__MODULE__{} = row, active) do
    stamp = if active, do: nil, else: DateTime.truncate(DateTime.utc_now(), :second)

    row
    |> change(active: active)
    |> force_change(:deactivated_at, stamp)
  end

  # A reset writes the hash and nothing else: the password is the only thing
  # the operator is replacing, and the sessions it kills are separate rows.
  def password_changeset(%__MODULE__{} = row, password_hash) do
    change(row, password_hash: password_hash)
  end
end
