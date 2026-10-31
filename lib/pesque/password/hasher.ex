defmodule Pesque.Password.Hasher do
  @moduledoc """
  The password hashing primitive Pesque.Password runs behind its permit gate.

  The behaviour exists so the gate and the option plumbing can be tested against
  a deterministic implementation. The NIF cannot be asked what options it was
  handed, and a timing assertion measures the machine rather than the code, so
  the seam is the hasher itself: swap it for a fake and the options, the gate,
  and the release on raise become observable.
  """

  @doc "Hashes a password with the given argon2 options, returning the encoded hash."
  @callback hash(password :: binary(), opts :: keyword()) :: binary()

  @doc "Verifies a password against an encoded hash. False on a mismatch."
  @callback verify(password :: binary(), stored_hash :: binary()) :: boolean()

  @doc "A dummy hash for an identifier no row names, at the given options."
  @callback no_user_verify(opts :: keyword()) :: boolean()
end
