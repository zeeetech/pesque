defmodule Pesque.RepoGenesisTest do
  @moduledoc """
  Genesis: the commit that gives a repo a head before it has any record.

  The failure this covers is the one that used to be silent. `commit/2` takes
  the write lock at BEGIN and answers `{:error, :busy}` when another writer
  took the event seq first, which left the repo with no head at all: nothing
  retried it, so the account stayed headless until somebody happened to write
  to it. These tests hold the event seq hostage to force exactly that answer
  and then release it, which is the same thing two RepoServers racing at boot
  do to each other, so the retry is exercised without a production-only seam.

  Waiting is real rather than injected. The first retry is a fifth of a second
  away, so a test that waits for the head pays only what production pays.

  What the assertions read is the RepoServer's own `rev`, not the stored one.
  Inside the sandbox the RepoServer's transaction is nested in the test's, and
  Ecto answers a rollback there by catching it at the inner boundary without
  unwinding the outer transaction, so the `rev` meta row of a rolled-back
  attempt survives in the test's database. The process state is the honest
  signal of what the commit answered, and it is the thing the bug was about.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event
  alias Pesque.RepoSupervisor
  alias Pesque.Tid

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "a genesis that rolls back is retried until it lands" do
    did = did("genesis-retry")
    held = hold_the_next_seq()

    log =
      capture_log(fn ->
        {:ok, pid} = RepoSupervisor.ensure_started(did)

        # A call, so it is answered after the genesis attempt that ran at
        # init: the seq was taken and the transaction rolled back whole, which
        # is what leaves the rev unset and the retry pending.
        assert RepoServer.entries(pid) == %{}
        assert rev(pid) == nil

        # The other writer finishing, which is what lets the retry through.
        release(held)

        assert eventually(fn -> rev(pid) != nil end)
        assert head(did) == rev(pid)

        # Past the first retry by a wide margin: the retry that landed wrote
        # one genesis commit and then stopped, rather than one per attempt.
        Process.sleep(600)
        assert events(did) == 1
        assert Process.alive?(pid)
      end)

    assert log =~ "genesis commit rolled back"
    assert log =~ did
    assert log =~ ":busy"
  end

  test "a retry firing after the head exists writes nothing" do
    did = did("genesis-late-retry")
    {:ok, pid} = RepoSupervisor.ensure_started(did)

    assert eventually(fn -> rev(pid) != nil end)
    settled = rev(pid)
    assert events(did) == 1

    # What a timer left pending would send. The rev guard answers it, so the
    # answer is that nothing happened: no second commit, no second frame.
    send(pid, :genesis_retry)
    Process.sleep(200)

    assert rev(pid) == settled
    assert events(did) == 1
  end

  test "a repo that already has a head neither genesis nor schedules a retry" do
    did = did("genesis-not-needed")
    {existing, _} = Tid.next(0, 0)
    RepoStore.put_meta!("rev:" <> did, existing)
    RepoStore.put_meta!("tid_int:" <> did, "0")
    before = RepoStore.max_seq()
    {:ok, pid} = RepoSupervisor.ensure_started(did)

    # Long enough for a first retry to have fired, and been logged, if one had
    # been scheduled.
    log = capture_log(fn -> Process.sleep(600) end)

    assert Process.alive?(pid)
    assert rev(pid) == existing
    assert RepoStore.max_seq() == before
    refute log =~ "genesis"
  end

  # The seq claim is a read of the mark plus one, and insert_event!/3 rolls the
  # transaction back when the log already holds it. Pinning the mark and
  # writing a row at the seq it claims is the same collision, from outside the
  # process, that two racing commits produce between themselves: the mark goes
  # down first because otherwise the claim falls back to the log's own maximum,
  # which the row below has just moved.
  defp hold_the_next_seq do
    held = RepoStore.claim_event_seq()
    RepoStore.put_meta!("event:seq", Integer.to_string(held - 1))

    Repo.insert!(%Event{
      seq: held,
      did: "did:web:localhost:user:seq-holder",
      payload: <<>>,
      inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
    })

    held
  end

  defp release(seq), do: Repo.delete_all(from e in Event, where: e.seq == ^seq)

  defp rev(pid), do: :sys.get_state(pid).rev

  defp head(did), do: RepoStore.get_meta("rev:" <> did)

  defp events(did), do: Repo.aggregate(from(e in Event, where: e.did == ^did), :count)

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  defp did(name), do: "did:web:localhost:user:" <> name <> suffix()
  defp suffix, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
