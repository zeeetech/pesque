defmodule Pesque.OAuth.Token do
  @moduledoc """
  A server-side record of one issued token: the access token or the refresh
  token that will replace it.

  Both kinds live here because both have to be revocable and because a refresh
  is only valid while the session it belongs to is. `session_id` is what ties
  a pair together, so revoking a session revokes every token under it in one
  statement.

  `used_at` is what makes a refresh token single use. It is written by the
  conditional update that spends the token, so two concurrent refreshes of one
  refresh token produce one new pair and one failure rather than two pairs
  that are both nominally live.

  The token itself is stored as its hash. Unlike a jti, which is only ever
  compared in this process, a token arrives from a stranger on every request
  and a row must not be enough to impersonate the holder.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @access "access"
  @refresh "refresh"

  schema "oauth_tokens" do
    field :token_hash, :string
    field :jti, :string
    field :kind, :string
    field :did, :string
    field :client_id, :string
    field :scope, :string
    field :dpop_jkt, :string
    field :session_id, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked, :boolean, default: false

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :token_hash,
      :jti,
      :kind,
      :did,
      :client_id,
      :scope,
      :dpop_jkt,
      :session_id,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :jti,
      :kind,
      :did,
      :client_id,
      :scope,
      :dpop_jkt,
      :session_id,
      :expires_at
    ])
    |> validate_inclusion(:kind, [@access, @refresh])
    |> unique_constraint(:token_hash)
    |> unique_constraint(:jti)
  end

  def access, do: @access
  def refresh, do: @refresh

  def hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
