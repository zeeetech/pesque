defmodule Pesque.OAuth.Nonce do
  @moduledoc """
  The server-issued DPoP nonce, which the atproto profile makes mandatory.

  One nonce is live for the whole server, which the spec allows: it binds a
  proof to this authorization server, not to a session. What it must not be is
  absent or stale, because a nonce the client never had to fetch proves
  nothing about a replay across servers.

  The lifetime is three minutes, under the five the spec allows as a maximum.
  Rotation replaces the row rather than adding one, so the table is one row
  however long the server runs, and the nonce it replaces is kept in
  `previous` for its own lifetime: a client with two requests in flight when
  the rotation happened must not have the earlier one rejected.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Pesque.Repo

  @max_age_seconds 180

  schema "oauth_dpop_nonces" do
    field :nonce, :string
    field :previous, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:nonce, :previous, :expires_at])
    |> validate_required([:nonce, :expires_at])
    |> unique_constraint(:nonce)
  end

  @doc """
  The nonce to hand out right now, minting or rotating one when needed.

  Rotating means a client that asks twice in a row is handed the same nonce,
  and a client that has been idle long enough is handed a new one without
  having asked.
  """
  def current do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case live(now) do
      %{nonce: nonce} -> nonce
      nil -> rotate(now).nonce
    end
  end

  @doc """
  Whether a proof's nonce is one this server issued and has not retired.

  A missing nonce and a wrong one are the same failure and answer the same way:
  `use_dpop_nonce`, with the live nonce in the response header. A client that
  retries with it is doing exactly what RFC 9449 section 8 describes.
  """
  def check(nil), do: {:error, :use_dpop_nonce}

  def check(nonce) when is_binary(nonce) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case live(now) do
      %{nonce: ^nonce} -> :ok
      %{previous: ^nonce} -> :ok
      _ -> {:error, :use_dpop_nonce}
    end
  end

  def check(_nonce), do: {:error, :use_dpop_nonce}

  @doc "Seconds a nonce stays live. Bounded by the five minutes the spec allows."
  def max_age_seconds, do: @max_age_seconds

  defp live(now) do
    Repo.one(
      from n in __MODULE__,
        where: n.expires_at > ^now,
        order_by: [desc: n.inserted_at],
        limit: 1
    )
  end

  # The row is deleted before the new one is written so the table never holds
  # two live nonces, which would make "the current nonce" ambiguous.
  defp rotate(now) do
    previous = live(now)
    expires_at = DateTime.add(now, @max_age_seconds, :second)
    attrs = %{nonce: generate(), previous: previous && previous.nonce, expires_at: expires_at}

    {:ok, row} =
      Repo.transaction(fn ->
        Repo.delete_all(from(n in __MODULE__))
        Repo.insert!(changeset(attrs))
      end)

    row
  end

  defp generate, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
