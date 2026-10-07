defmodule Pesque.OAuth.Nonce do
  @moduledoc """
  The server-issued DPoP nonce, which the atproto profile makes mandatory.

  One nonce is live for the whole server, which the spec allows: it binds a
  proof to this authorization server, not to a session. What it must not be is
  absent or stale, because a nonce the client never had to fetch proves
  nothing about a replay across servers.

  The lifetime is three minutes, under the five the spec allows as a maximum.
  Rotation replaces the live nonce rather than adding one, so the term holds
  one entry however long the server runs, and the nonce it replaces is kept in
  `previous` for its own lifetime: a client with two requests in flight when
  the rotation happened must not have the earlier one rejected.

  Held in `:persistent_term` rather than a table because it is read on every
  DPoP-answered request and a restart minting a fresh one is harmless: the
  client retries on `use_dpop_nonce`. The same idiom as Pesque.Secret.
  """

  @key {__MODULE__, :nonce}
  @max_age_seconds 180

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

  defp live(now) do
    case :persistent_term.get(@key, nil) do
      %{expires_at: expires_at} = state ->
        if DateTime.after?(expires_at, now), do: state, else: nil

      _other ->
        nil
    end
  end

  # Rotation is serialized so two processes hitting an expired nonce at the
  # same instant cannot each install one: the second sees the first's nonce as
  # current and keeps it, and the nonce it replaced stays in `previous`. The
  # requester is self() because :global only contends on a resource between
  # different requesters.
  defp rotate(now) do
    :global.trans({__MODULE__, self()}, fn -> rotate_locked(now) end)
  end

  defp rotate_locked(now) do
    case live(now) do
      %{nonce: _nonce} = state ->
        state

      nil ->
        previous =
          case :persistent_term.get(@key, nil) do
            %{nonce: nonce} -> nonce
            _other -> nil
          end

        state = %{
          nonce: generate(),
          previous: previous,
          expires_at: DateTime.add(now, @max_age_seconds, :second)
        }

        :persistent_term.put(@key, state)
        state
    end
  end

  defp generate, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
