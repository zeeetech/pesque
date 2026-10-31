defmodule Pesque.PasswordTest do
  @moduledoc """
  The argon2 options and the permit gate, against an injected hasher.

  The dummy verify returns false and discards its hash, and a timing assertion
  would measure the machine rather than the code, so nothing outside the NIF can
  observe the cost a hash or the dummy verify ran at. The seam is the hasher
  itself: a fake records the options it was handed and the permit count at the
  moment it ran, so "the dummy verify reads the same options as a real hash" and
  "every argon2 call runs inside the gate" become real, deterministic
  assertions instead of regular expressions over this module's source.
  """

  use ExUnit.Case, async: false

  alias Pesque.Password

  # Records what it was handed and the permit count while running, then answers
  # deterministically. self/0 is the caller, which is the test process for the
  # direct-call assertions below.
  defmodule FakeHasher do
    @behaviour Pesque.Password.Hasher

    @impl true
    def hash(password, opts) do
      send(self(), {:hash, password, opts, Pesque.Password.in_use()})
      "hashed:" <> password
    end

    @impl true
    def verify(password, stored_hash) do
      send(self(), {:verify, password, stored_hash, Pesque.Password.in_use()})
      stored_hash == "hashed:" <> password
    end

    @impl true
    def no_user_verify(opts) do
      send(self(), {:dummy, opts, Pesque.Password.in_use()})
      false
    end
  end

  # The NIF raises out of a gated call in production; this stands in for it so
  # the release-on-raise path can be asserted without a malformed hash.
  defmodule RaisingHasher do
    @behaviour Pesque.Password.Hasher

    @impl true
    def hash(_password, _opts), do: raise("boom")

    @impl true
    def verify(_password, _stored_hash), do: raise("boom")

    @impl true
    def no_user_verify(_opts), do: raise("boom")
  end

  @password "hunter2hunter2"

  test "opts returns what the operator configured" do
    assert Password.opts() == Application.get_env(:pesque, :argon2_opts, [])

    with_opts(t_cost: 2, m_cost: 12)

    assert Password.opts() == [t_cost: 2, m_cost: 12]
  end

  test "the dummy verify and a real hash read the same configured options" do
    with_opts(t_cost: 2, m_cost: 12)

    assert {:ok, "hashed:" <> @password} = Password.hash(@password, FakeHasher)
    assert_received {:hash, @password, hash_opts, 1}

    refute Password.dummy_verify(FakeHasher)
    assert_received {:dummy, dummy_opts, 1}

    assert hash_opts == [t_cost: 2, m_cost: 12]
    assert dummy_opts == hash_opts
  end

  test "a real hash runs inside the gate and gives the permit back" do
    assert Password.in_use() == 0

    assert {:ok, _hash} = Password.hash(@password, FakeHasher)

    assert_received {:hash, _, _, 1}
    assert Password.in_use() == 0
  end

  test "a verify runs inside the gate and gives the permit back" do
    assert Password.verify(@password, "hashed:" <> @password, FakeHasher)
    assert_received {:verify, _, _, 1}
    assert Password.in_use() == 0

    refute Password.verify("wrong", "hashed:" <> @password, FakeHasher)
    assert_received {:verify, _, _, 1}
    assert Password.in_use() == 0
  end

  test "a non-binary password spends no permit and answers false" do
    refute Password.verify([], "hashed:" <> @password, FakeHasher)

    assert Password.in_use() == 0
    refute_received {:verify, _, _, _}
  end

  test "a raise inside the gate still gives the permit back" do
    assert_raise RuntimeError, fn -> Password.hash(@password, RaisingHasher) end

    assert Password.in_use() == 0
  end

  test "the permit count is bounded by the machine, not by the caller" do
    assert Password.permit_limit() in 2..8
  end

  # A permit is an internal counter, so the bound is only observable while it is
  # saturated: hold every permit, then show a further hash cannot finish until
  # one is released. That fails on a gate that stopped bounding (the extra
  # finishes immediately) and on one that leaked a permit (fewer than the limit
  # are holdable).
  test "the gate holds at most permit_limit hashes at once" do
    limit = Password.permit_limit()
    parent = self()

    holders =
      for i <- 1..limit do
        Task.async(fn ->
          Password.with_permit(fn ->
            send(parent, {:holding, i})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    for i <- 1..limit, do: assert_receive({:holding, ^i})
    assert Password.in_use() == limit

    extra = Task.async(fn -> Password.with_permit(fn -> :extra_done end) end)

    assert Task.yield(extra, 100) == nil, "a hash ran while every permit was held"
    assert Password.in_use() == limit

    for task <- holders, do: send(task.pid, :release)
    Task.await_many(holders, 5_000)

    assert Password.in_use() == 0
    assert Task.await(extra, 5_000) == :extra_done
  end

  defp with_opts(opts) do
    previous = Application.get_env(:pesque, :argon2_opts)

    on_exit(fn -> Application.put_env(:pesque, :argon2_opts, previous) end)

    Application.put_env(:pesque, :argon2_opts, opts)
  end
end
