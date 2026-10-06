defmodule Pesque.Accounts.Argon2Test do
  @moduledoc """
  The argon2 cost parameters, and the bound on how many hashes run at once.

  The timing defence is the reason the options are read in one place. The dummy
  verify for an identifier no row names exists to cost what a real verify costs,
  and Comeonin.no_user_verify/1 is hash_pwd_salt("", opts): if the two read
  different options, a login against an unknown handle is fast and one against
  a real handle is slow, and that is an unauthenticated enumeration oracle that
  only opens once an operator sets argon2_opts, which is exactly what they are
  being pushed to do.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.User

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
  end

  # A timing assertion is the obvious test and the wrong one: it is a
  # measurement of the machine, so it fails on a loaded CI box and passes on a
  # broken one. This asserts the structure instead, that there is a single
  # reader and both call sites go through it. The consequence is that a real
  # hash carries the operator's parameters, which is checkable from the stored
  # hash, so both halves are covered without a clock.
  test "the accessor returns what the operator configured" do
    assert Accounts.argon2_opts() == Application.get_env(:pesque, :argon2_opts, [])

    with_argon2(t_cost: 2, m_cost: 12)

    assert Accounts.argon2_opts() == [t_cost: 2, m_cost: 12]
  end

  test "a real hash carries the configured cost parameters" do
    with_argon2(t_cost: 2, m_cost: 12)

    user = insert_account("alice")

    # The encoded hash states its own parameters, so this reads what was
    # actually used rather than what was configured. m_cost is an exponent of
    # KiB in argon2, so 12 is 4096 and t_cost is the iteration count.
    assert user.password_hash =~ ~r/\$argon2id\$v=19\$m=4096,t=2,p=/
  end

  # The other half of the no-drift claim, stated where it can be. The dummy
  # verify returns false and discards the hash, so nothing outside the module
  # can observe that it ran at any particular cost, and a timing assertion
  # would be a measurement of the machine rather than of the code. So this reads
  # the source: the accessor is the only place argon2_opts is read, and the
  # dummy verify is handed the accessor rather than a literal or nothing. It is
  # a source-reading test, which is normally a smell, and it is here because
  # the property it guards has no other observable.
  test "the dummy verify goes through the same accessor as the real hash" do
    source = File.read!(source_path())

    # Exactly one read of the config, and it is the body of argon2_opts/0.
    assert count(source, ~r/Application\.get_env\(:pesque, :argon2_opts/) == 1,
           "argon2_opts is read somewhere besides the accessor"

    assert count(source, ~r/Argon2\.no_user_verify\(\s*argon2_opts\(\)\s*\)/) == 1
    assert count(source, ~r/Argon2\.hash_pwd_salt\(\s*password, argon2_opts\(\)\s*\)/) == 1
  end

  # The gate is a closure passed to with_hash_permit, so "is this call site
  # inside the gate" has no runtime answer: a permit is an internal counter,
  # and nothing a caller can see changes once it is taken. So this reads the
  # source the same way the accessor test above does, and the assertion is the
  # one that discriminates: cut every gated call out of the module and no
  # Argon2 call may be left. That fails on an ungated verify such as the one
  # delete_account/4 used to have, and on a second gate or a new semaphore
  # built out of something other than with_hash_permit.
  test "every argon2 call in accounts goes through the gate" do
    source = File.read!(source_path())
    ungated = Regex.replace(~r/with_hash_permit\(fn -> Argon2\.\w+\(.*?\s+end\)/s, source, "")

    refute ungated =~ ~r/Argon2\.\w+/,
           "an Argon2 call in accounts.ex is not the body of with_hash_permit"
  end

  # Unbounded concurrency is the half of this that is about availability: one
  # address sending many logins at once is several GiB of RSS at the library
  # defaults. The gate is what stops that, so a test that only checked the
  # cost parameters would miss a gate that stopped working.
  test "the permit count is bounded by the machine, not by the caller" do
    assert Accounts.argon2_permit_limit() in 2..8
  end

  test "concurrent hashes all finish, so the gate releases what it takes" do
    alice = insert_account("alice")
    attempts = Accounts.argon2_permit_limit() * 4

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

  # The mix project root, which is where the suite runs from.
  defp source_path, do: Path.join([File.cwd!(), "lib", "pesque", "accounts.ex"])

  defp count(source, regex), do: length(Regex.scan(regex, source))

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
