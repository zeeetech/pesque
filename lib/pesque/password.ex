defmodule Pesque.Password do
  @moduledoc """
  Password hashing, verification, and the concurrency budget that bounds both.

  Every argon2 call on a request path goes through here so two properties hold
  in one place. The first is that a real hash, a real verify, and the dummy
  verify for an identifier no row names all read the operator's options from a
  single accessor: Comeonin.no_user_verify/1 is hash_pwd_salt("", opts), so if
  the two read different options a login against an unknown handle is fast and
  one against a real handle is slow, which is an unauthenticated enumeration
  oracle that only opens once an operator sets argon2_opts.

  The second is the gate. argon2 is memory-hard: one verify holds tens of MiB at
  the defaults, and nothing above this module bounds how many logins a client has
  in flight (Bandit takes no connection cap, and the session rate limit bounds
  volume rather than concurrency), so a hundred concurrent createSession calls
  is several GiB of RSS. A counting semaphore via :atomics, not a pool of
  workers: a permit costs one atomic add, and there is nothing to supervise and
  no mailbox to serialise. The waiter sleeps between attempts rather than
  spinning; the hashes want the cores.

  The counter is created once at application startup, so a login never pays for
  the first-touch race and the budget is a thing an operator can say exists
  before a request arrives (Pesque.Password.init/0, called from
  Pesque.Application.start/2).
  """

  alias Pesque.Password.Argon2

  # Sized against the schedulers, floored at 2 for a one-core box, and capped so
  # a many-core machine does not size the gate by hardware instead of by memory.
  @permit_floor 2
  @permit_ceiling 8
  @permit_retry_ms 5
  @permits {__MODULE__, :permits}

  @doc """
  Creates the permit counter, once, at application startup.

  Kept out of the request path on purpose: the old lazy :persistent_term
  initialisation let two first logins race to install equivalent counters, and
  made "the budget exists" something only the first request could observe. Doing
  it at boot makes the budget a startup invariant.
  """
  def init do
    :persistent_term.put(@permits, :atomics.new(1, signed: false))
    :ok
  end

  @doc """
  Hashes a password, inside the permit gate.

  Answers `{:ok, hash}`. The caller runs the hashing outside any database
  transaction: argon2 would otherwise hold SQLite's single write lock for the
  whole hash.
  """
  def hash(password), do: hash(password, Argon2)

  @doc false
  def hash(password, hasher) when is_binary(password) do
    {:ok, with_permit(fn -> hasher.hash(password, opts()) end)}
  end

  @doc """
  Verifies a password against a stored hash, inside the permit gate.

  A non-binary password is answered false rather than raising out of the NIF:
  only the branch that found an account reaches the NIF, so a malformed body is
  a clean 401 for an unknown handle and a 500 for a known one without this
  clause, which is an unauthenticated answer to "is this handle registered".
  """
  def verify(password, hash), do: verify(password, hash, Argon2)

  @doc false
  def verify(password, hash, hasher) when is_binary(password),
    do: with_permit(fn -> hasher.verify(password, hash) end)

  def verify(_password, _hash, _hasher), do: false

  @doc """
  The dummy verify for an identifier no row names.

  Same options and same gate as a real verify: it has to be indistinguishable
  from one in cost and timing, or the unknown-handle branch is the fast one.
  """
  def dummy_verify, do: dummy_verify(Argon2)

  @doc false
  def dummy_verify(hasher), do: with_permit(fn -> hasher.no_user_verify(opts()) end)

  # The one place argon2 options are read. m_cost is an exponent of KiB, so
  # m_cost 16 is 65536 KiB per hash: configurable because the right number is a
  # function of the box, and anything above about m_cost 15 wants the permit
  # count looked at again.
  @doc false
  def opts, do: Application.get_env(:pesque, :argon2_opts, [])

  @doc false
  def permit_limit,
    do: min(@permit_ceiling, max(@permit_floor, System.schedulers_online()))

  @doc false
  def in_use, do: :atomics.get(permits(), 1)

  @doc false
  def with_permit(fun) do
    acquire_permit()

    # Released in an after, so a raise out of the NIF cannot leak a permit and
    # wedge the gate for every login after it.
    try do
      fun.()
    after
      :atomics.sub(permits(), 1, 1)
    end
  end

  defp acquire_permit do
    permits = permits()
    limit = permit_limit()

    if :atomics.add_get(permits, 1, 1) <= limit do
      :ok
    else
      # Handed straight back rather than held while waiting, so a caller that
      # lost the race does not shrink the gate for everyone queued behind it.
      :atomics.sub(permits, 1, 1)
      Process.sleep(@permit_retry_ms)
      acquire_permit()
    end
  end

  # The counter is installed at boot. The fallback only covers contexts that call
  # a hash before the application started (a bare CLI runtime); it installs the
  # same counter rather than raising on the first login.
  defp permits do
    case :persistent_term.get(@permits, nil) do
      nil ->
        init()
        :persistent_term.get(@permits)

      permits ->
        permits
    end
  end
end
