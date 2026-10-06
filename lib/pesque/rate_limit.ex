defmodule Pesque.RateLimit do
  @moduledoc """
  Fixed-window counters for the endpoints the spec puts limits on.

  One GenServer owning one ETS table. The table is `:public` and every counter
  is written with `:ets.update_counter/4`, so a request increments its own
  window without a message to anything. The process exists to own the table,
  not to serve the reads.

  Fixed window, not sliding: the counters reset on a boundary rather than
  decaying, so a caller can spend a full window's budget at the end of one and
  a full window's at the start of the next. That is twice the limit across the
  seam. It buys having no timer per key; the only cleanup is one periodic
  sweep of windows that have already reset, which for a homelab PDS is the
  trade worth making. `pesque: rate limit a caller at the
  window boundary` if a deployment ever needs it.

  Windows are sized by the caller passing a limit and a length. This module
  knows nothing about which endpoint is which.
  """

  use GenServer

  @table :pesque_rate_limit

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_, :"$2"}, [{:>=, {:const, now}, {:*, {:+, :"$1", 1}, :"$2"}}], [true]}
    ])

    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state}
  end

  @doc """
  Counts one call against `key` and answers whether it is within `limit`.

  `{:ok, count}` carries the calls made in this window so far, which is what
  the RateLimit-Remaining header reports. `{:error, retry_after_ms}` carries
  how long until the window resets, which is what a 429 has to tell a client.
  """
  @spec hit(term(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, non_neg_integer()}
  def hit(key, limit, window_ms) when is_integer(limit) and is_integer(window_ms) do
    now = System.monotonic_time(:millisecond)
    window = Integer.floor_div(now, window_ms)
    key = {key, window}

    count = :ets.update_counter(@table, key, {2, 1}, {{key, window}, 0, window_ms})

    if count > limit do
      # Integer.mod/2, not rem/2. The monotonic clock is negative before the
      # node has been up long enough, and rem/2 keeps the sign, which answers a
      # caller with a wait longer than the window it is being told to wait out.
      {:error, window_ms - Integer.mod(now, window_ms)}
    else
      {:ok, count}
    end
  rescue
    ArgumentError ->
      # The table is gone, which only happens while the application is stopping.
      # Refusing is the wrong answer to a shutdown, and so is a crash that takes
      # the request down with it, so this one passes.
      {:ok, 0}
  end
end
