defmodule Pesque.RateLimitSweepTest do
  @moduledoc """
  The table's own maintenance: what the sweep reclaims and what the row cap
  does when there are more keys than the table is willing to hold.

  Its own file and not async, because both tests empty or reshape the one
  counter table the rest of the suite is counting in.
  """

  use ExUnit.Case, async: false

  alias Pesque.RateLimit

  @table :pesque_rate_limit
  @window 60_000

  setup do
    on_exit(fn -> Application.delete_env(:pesque, :rate_limit_max_rows) end)
    :ok
  end

  # Fixed windows mean every row outlives its window by up to one sweep
  # interval, so the sweep is the only thing that ever reclaims one. If its
  # match stopped matching, nothing else would notice: counters would keep
  # answering correctly and the table would grow until the node ran out of
  # memory.
  test "the sweep reclaims elapsed windows and keeps current ones" do
    current = current_window()
    # Two windows back, not one: a row in the window just past has not elapsed
    # yet, and the boundary is what the guard is asking.
    elapsed = current - 2

    stale = insert({:stale, unique()}, elapsed)
    live = insert({:live, unique()}, current)

    RateLimit.handle_info(:sweep, nil)

    assert :ets.lookup(@table, stale) == []
    assert :ets.lookup(@table, live) != []
  end

  # Bounded keys still leave an attacker free to send a different one per
  # request, and every different one is a row the sweep cannot reclaim until its
  # window closes. Dropping the table costs everyone up to one window of budget
  # and bounds the table; the alternative is an OOM, which bounds nothing.
  test "the table is cleared once it is over the cap" do
    Application.put_env(:pesque, :rate_limit_max_rows, 5)

    keys = for _ <- 1..6, do: insert({:flood, unique()}, current_window())
    assert Enum.all?(keys, &match?([_], :ets.lookup(@table, &1)))

    RateLimit.handle_info(:sweep, nil)

    assert :ets.info(@table, :size) == 0
  end

  test "a table under the cap is left alone" do
    Application.put_env(:pesque, :rate_limit_max_rows, 100)

    key = insert({:quiet, unique()}, current_window())

    RateLimit.handle_info(:sweep, nil)

    assert :ets.lookup(@table, key) != []
  end

  defp current_window, do: Integer.floor_div(System.monotonic_time(:millisecond), @window)

  defp insert(key, window) do
    key = {key, window}
    :ets.insert(@table, {key, 1, @window})
    key
  end

  defp unique, do: {__MODULE__, System.unique_integer([:positive])}
end
