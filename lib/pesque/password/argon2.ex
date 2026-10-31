defmodule Pesque.Password.Argon2 do
  @moduledoc """
  The production Pesque.Password.Hasher, backed by argon2_elixir.

  Thin on purpose: every call here is already inside the permit gate and handed
  the operator's options by Pesque.Password, so this module only names the NIF.
  """

  @behaviour Pesque.Password.Hasher

  @impl true
  def hash(password, opts), do: Argon2.hash_pwd_salt(password, opts)

  @impl true
  def verify(password, stored_hash), do: Argon2.verify_pass(password, stored_hash)

  @impl true
  def no_user_verify(opts), do: Argon2.no_user_verify(opts)
end
