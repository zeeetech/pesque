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
    # deactivate_account/activate_account.
    field :active, :boolean, default: true

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

  def handle_changeset(%__MODULE__{} = row, overrides) do
    row
    |> change(overrides)
    |> validate_required([:handle])
    |> unique_constraint(:handle)
  end

  def active_changeset(%__MODULE__{} = row, active) do
    change(row, active: active)
  end
end
