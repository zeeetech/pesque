defmodule Pesque.OAuth.Request do
  @moduledoc """
  A pushed authorization request, and later the code it authorizes.

  One row carries the whole request: what the client pushed, the DPoP key it
  pushed it with, and then, once a human has approved, the account and the
  code. Keeping them together is what makes a request single-use: `did` and
  `code_hash` are set by one conditional update, so the second attempt to
  approve the same request_uri finds nothing to update.

  The request_uri and the code are stored hashed. Either one is a bearer
  credential, and a row read out of this table must not be enough to finish
  somebody else's flow.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "oauth_requests" do
    field :request_uri_hash, :string
    field :client_id, :string
    field :redirect_uri, :string
    field :state, :string
    field :scope, :string
    field :code_challenge, :string
    field :code_challenge_method, :string
    field :login_hint, :string
    field :dpop_jkt, :string
    field :did, :string
    field :code_hash, :string
    field :code_expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :request_uri_hash,
      :client_id,
      :redirect_uri,
      :state,
      :scope,
      :code_challenge,
      :code_challenge_method,
      :login_hint,
      :dpop_jkt,
      :expires_at
    ])
    |> validate_required([
      :request_uri_hash,
      :client_id,
      :redirect_uri,
      :state,
      :scope,
      :code_challenge,
      :code_challenge_method,
      :dpop_jkt,
      :expires_at
    ])
    |> unique_constraint(:request_uri_hash)
  end

  def hash(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)
end
