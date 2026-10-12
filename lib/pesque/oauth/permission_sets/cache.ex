defmodule Pesque.OAuth.PermissionSets.Cache do
  @moduledoc """
  The table the permission-set resolver reads, one GenServer owning one
  `:public` `:set` ETS table: the `Pesque.RateLimit` pattern, sized for a
  smaller tenant.

  Reads are direct `:ets.lookup/2` from the calling process and writes land
  from whoever resolved the document, so the cache is read-through and nothing
  refreshes in the background. The owner's only job is a periodic sweep of
  rows past the expiration, which is what keeps a table of a few hundred bytes
  per set from growing without end.

  A row is `{nsid, document, fetched_at_ms}`, stamped with the wall clock so
  the day and the ninety days mean what a calendar would mean by them.
  """

  use GenServer

  @table :pesque_permission_sets
  @sweep_ms 60_000

  # Ninety days is the specification's expiration for a cached permission
  # set, and it is read in two places: by this sweep and by the resolver's
  # staleness check. One definition, shared through expiration_ms/0.
  @expiration_ms 90 * 24 * 60 * 60 * 1000

  @doc "The lifetime of a cached document, in milliseconds: ninety days."
  def expiration_ms, do: @expiration_ms

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The cached document for `nsid`, with the wall clock it was fetched at.

  nil on a miss. The timestamp is returned with the document because
  staleness is decided by the caller, which is the process already standing on
  a network-touching path.
  """
  @spec get(binary()) :: {document :: map(), fetched_at :: integer()} | nil
  def get(nsid) do
    case :ets.lookup(@table, nsid) do
      [{^nsid, document, fetched_at}] -> {document, fetched_at}
      [] -> nil
    end
  rescue
    # The table is gone, which only happens while the application is stopping.
    # A resolver reading a shutting-down cache reads a miss.
    ArgumentError -> nil
  end

  @doc "Caches `document` for `nsid`, stamped with `fetched_at` (now by default)."
  @spec put(binary(), map(), integer()) :: :ok
  def put(nsid, document, fetched_at \\ System.system_time(:millisecond)) do
    true = :ets.insert(@table, {nsid, document, fetched_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    horizon = System.system_time(:millisecond) - @expiration_ms

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", {:const, horizon}}], [true]}])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
