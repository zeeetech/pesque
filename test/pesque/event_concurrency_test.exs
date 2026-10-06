defmodule Pesque.EventConcurrencyTest do
  @moduledoc """
  Two connections writing the firehose log at the same time.

  The sandbox cannot say this. In shared mode every process is routed to the
  one connection the test checked out, so two commits meant to contend arrive
  as one connection taking one transaction and never overlap at all. Each task
  here checks out its own connection outside any transaction and commits for
  real, and the rows it wrote are cleaned up by hand afterwards because a
  sandbox rollback has nothing left to roll back.

  The writers go through Pesque.Events rather than a copy of its transaction,
  so what runs here is the BEGIN the account and commit paths actually issue.
  Three is as many as this harness holds at once: past that it runs out of
  pool before it runs out of log.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Pesque.CBOR
  alias Pesque.Events
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event
  alias Pesque.RepoStore.Meta

  @seq_key "event:seq"

  setup do
    # No owner, so every task below gets a connection of its own instead of the
    # shared one the rest of the suite routes everything through.
    :ok = Sandbox.mode(Repo, :manual)

    {:ok, mark, highest} = baseline()

    on_exit(fn ->
      :ok = restore(mark, highest)
    end)

    %{highest: highest}
  end

  test "commits racing on the log all land, on one gap-free sequence", ctx do
    test = self()
    writers = ["carol", "dave", "carol"]

    tasks =
      Enum.map(writers, fn name ->
        did = account(name)

        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          send(test, {:ready, self()})

          assert_receive :go

          result = Events.emit_identity(did, handle(did))
          Sandbox.checkin(Repo)
          result
        end)
      end)

    # The barrier is what makes them contend: every writer holds its own
    # connection and asks for the write lock at the same moment.
    Enum.each(tasks, fn _ -> assert_receive {:ready, _} end)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)

    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, _frame}, &1)),
           "a concurrent commit did not land: #{inspect(results)}"

    frames = Enum.map(results, fn {:ok, frame} -> frame end)
    seqs = Enum.map(frames, &field(&1, "seq"))

    assert Enum.sort(seqs) == Enum.to_list((ctx.highest + 1)..(ctx.highest + 3))

    rows = persisted(ctx.highest)

    assert Enum.map(rows, & &1.seq) == Enum.sort(seqs)
    assert Enum.sort(Enum.map(rows, & &1.did)) == Enum.sort(Enum.map(frames, &field(&1, "did")))
  end

  defp baseline do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    mark = RepoStore.get_meta(@seq_key)
    highest = RepoStore.max_seq()
    Sandbox.checkin(Repo)
    {:ok, mark, highest}
  end

  # Nothing here rolls back, so the mark goes back to what it was and the rows
  # above the baseline go away. Leaving either behind would move the sequence
  # every later test writes into.
  defp restore(mark, highest) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Repo.delete_all(from e in Event, where: e.seq > ^highest)

    if mark do
      RepoStore.put_meta!(@seq_key, mark)
    else
      Repo.delete_all(from m in Meta, where: m.key == ^@seq_key)
    end

    Sandbox.checkin(Repo)
    :ok
  end

  defp persisted(highest) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    rows = Repo.all(from e in Event, where: e.seq > ^highest, order_by: e.seq)
    Sandbox.checkin(Repo)
    rows
  end

  defp field(frame, key) do
    {_header, rest} = CBOR.decode(frame)
    {%{^key => value}, _rest} = CBOR.decode(rest)
    value
  end

  defp account(name), do: "did:web:localhost:user:" <> name <> suffix()
  defp handle(did), do: String.replace_prefix(did, "did:web:localhost:user:", "") <> ".localhost"

  defp suffix, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
