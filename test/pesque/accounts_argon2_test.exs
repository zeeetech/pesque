defmodule Pesque.Accounts.Argon2Test do
  @moduledoc """
  The cost parameters as they reach a stored account hash, and the gate as the
  account login path exercises it.

  The option accessor, the gate itself, and the "dummy verify reads the same
  options as a real hash" claim now live in Pesque.Password, where they are
  asserted against an injected hasher rather than by reading source text. What
  stays here is the part only a real account can show: the hash a created
  account stores carries the operator's parameters, and a burst of concurrent
  logins all finish because the gate releases every permit it takes.
  """

  use Pesque.DataCase, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Password

  @password "hunter2hunter2"

  setup do
    put_mode(:multi)
  end

  test "a real hash carries the configured cost parameters" do
    with_argon2(t_cost: 2, m_cost: 12)

    user = insert_account("alice")

    # The encoded hash states its own parameters, so this reads what was
    # actually used rather than what was configured. m_cost is an exponent of
    # KiB in argon2, so 12 is 4096 and t_cost is the iteration count.
    assert user.password_hash =~ ~r/\$argon2id\$v=19\$m=4096,t=2,p=/
  end

  # Unbounded concurrency is the half of this that is about availability: one
  # address sending many logins at once is several GiB of RSS at the library
  # defaults. The gate is what stops that, so a test that only checked the
  # cost parameters would miss a gate that stopped working.
  test "concurrent hashes all finish, so the gate releases what it takes" do
    alice = insert_account("alice")
    attempts = Password.permit_limit() * 4

    results =
      1..attempts
      |> Task.async_stream(fn _ -> Accounts.verify_login(alice.handle, @password) end,
        max_concurrency: attempts
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %User{}}, &1)) == attempts
  end

  # A leaked permit is invisible until the gate is empty, at which point every
  # later login blocks forever. Counting what is left after the work is the
  # direct assertion, and it is cheap because the test cost parameters are
  # small.
  test "a failed verify gives its permit back" do
    alice = insert_account("alice")

    assert Accounts.verify_login(alice.handle, "wrong") == :error
    assert :error == Accounts.verify_login("nobody.localhost", @password)

    assert {:ok, %User{did: did}} = Accounts.verify_login(alice.handle, @password)
    assert did == alice.did
  end

  defp insert_account(name) do
    {:ok, user} = Accounts.create_account(name <> ".localhost", name <> "@localhost", @password)
    user
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end

  defp with_argon2(opts) do
    previous = Application.get_env(:pesque, :argon2_opts)

    on_exit(fn -> Application.put_env(:pesque, :argon2_opts, previous) end)

    Application.put_env(:pesque, :argon2_opts, opts)
  end
end
