defmodule Pesque.Secret do
  @moduledoc """
  The server HMAC secret that signs every access and refresh token.

  Held in :persistent_term because it is read on every authenticated request
  and never rewritten, and a put/2 there takes a global GC scan. Loaded once
  during boot, read from then on.
  """

  @key {__MODULE__, :secret}

  @doc "Reads the secret off disk and publishes it. Raises if it is not there yet."
  def load!, do: :persistent_term.put(@key, Pesque.Storage.server_secret!())

  @doc "The loaded secret. Raises if load!/0 has not run."
  def get, do: :persistent_term.get(@key)
end
