defmodule Pesque.Secret do
  @moduledoc """
  The server HMAC secret that signs every access and refresh token.

  Held in :persistent_term because it is read on every authenticated request
  and never rewritten, and a put/2 there takes a global GC scan. Loaded once
  during boot, read from then on.
  """

  @key {__MODULE__, :secret}

  def load!, do: :persistent_term.put(@key, Pesque.Storage.server_secret!())

  def get, do: :persistent_term.get(@key)
end
