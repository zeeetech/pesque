defmodule Pesque.EventReaper do
  @moduledoc """
  Periodic retention: drops firehose events past their window and blocks no
  current MST can reach.

  One GenServer owning one timer. Both sweeps are plain mark-and-delete over
  tables nothing else reads forever, and both are safe to interrupt: a sweep
  that dies halfway has deleted rows nothing needed, and the next tick picks
  up from whatever is left.

  Event retention is an age, not a seq window. A window in seqs would mean
  picking a write rate this server does not know and does not control, and
  getting it wrong either truncates history a relayer still wants or keeps it
  forever. Seven days is what a consumer that fell behind for a week needs, and
  the firehose already answers a cursor inside the dropped window with
  OutdatedCursor, which is the honest answer to a replay nobody can serve.

  Block GC runs per hosted repo, off one timer, not on the write path: a
  write cannot tell a superseded block from a reachable one without walking
  the whole tree, and the tree is walked far less often than it is written.
  """

  use GenServer

  require Logger

  alias Pesque.Accounts
  alias Pesque.RepoStore

  @retention_days 7
  @sweep_interval_ms :timer.hours(24)

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  @doc false
  def sweep do
    cutoff =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.add(-@retention_days, :day)

    events = RepoStore.delete_events_before(cutoff)

    blocks =
      Enum.reduce(Accounts.hosted_dids(), 0, fn did, acc -> acc + RepoStore.sweep_blocks!(did) end)

    Logger.info("reaped", events_deleted: events, blocks_deleted: blocks)
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
