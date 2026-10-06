defmodule Pesque.EventFramesTest do
  @moduledoc """
  The two firehose frames that are not commits, and the log they share with
  them: a cursor replaying from before an account existed has to hand back the
  #account frame in seq order with the commits around it.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.EventFrames
  alias Pesque.Events
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event
  alias Pesque.RepoServer

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
    :ok
  end

  test "an #identity frame carries the did, the handle and a time" do
    {header, body} = decode(EventFrames.identity(4, "did:web:localhost", "alice.localhost"))

    assert header == %{"op" => 1, "t" => "#identity"}
    assert body["seq"] == 4
    assert body["did"] == "did:web:localhost"
    assert body["handle"] == "alice.localhost"
    assert {:ok, _, 0} = DateTime.from_iso8601(body["time"])
  end

  test "an #account frame carries the status and the active flag that follows it" do
    statuses = [
      :takendown,
      :suspended,
      :deleted,
      :deactivated,
      :desynchronized,
      :throttled
    ]

    for status <- statuses do
      {header, body} = decode(EventFrames.account(2, "did:web:localhost", status))

      assert header == %{"op" => 1, "t" => "#account"}
      assert body["seq"] == 2
      assert body["did"] == "did:web:localhost"
      assert body["status"] == Atom.to_string(status)
      refute body["active"]
      assert {:ok, _, 0} = DateTime.from_iso8601(body["time"])
    end
  end

  test "an active #account frame carries no status, since there is nothing wrong with it" do
    {_header, body} = decode(EventFrames.account(2, "did:web:localhost", :activated))

    assert body["seq"] == 2
    assert body["did"] == "did:web:localhost"
    assert body["active"]
    refute Map.has_key?(body, "status")
  end

  test "creating an account announces an activated #account frame" do
    Registry.register(Pesque.EventRegistry, :firehose, [])

    cursor = RepoStore.max_seq()
    user = create("alice")

    assert_receive {:firehose_frame, frame}
    {_header, body} = decode(frame)
    assert body["did"] == user.did
    refute Map.has_key?(body, "status")
    assert body["active"]
    assert body["seq"] == cursor + 1
  end

  test "an #account frame is in the log, so a cursor replay returns it" do
    cursor = RepoStore.max_seq()
    user = create("alice")
    start_repo(user)

    replayed = RepoStore.events_after(cursor)

    assert [_account, _genesis] = replayed
    {header, body} = decode(hd(replayed))
    assert header["t"] == "#account"
    assert body["did"] == user.did

    # The socket answers a cursor with the same bytes the log holds, which is
    # what makes a reconnecting consumer see the account it missed.
    assert {:push, [{:binary, replay_frame} | _], _state} =
             PesqueWeb.Firehose.init(%{cursor: cursor})

    assert replay_frame == hd(replayed)
  end

  test "an #account frame and the commits around it share one sequence" do
    cursor = RepoStore.max_seq()
    pid = start_repo(create("alice"))

    {:ok, _} = RepoServer.create_record(pid, "app.bsky.feed.post", "1", post("hello"))

    seqs = Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq, select: e.seq)
    assert seqs == Enum.to_list((cursor + 1)..(cursor + 3))

    dids =
      Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq, select: e.did)

    assert [did, did, did] = dids

    types =
      Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq, select: e.payload)
      |> Enum.map(&(decode(&1) |> elem(0) |> Map.fetch!("t")))

    assert types == ["#account", "#commit", "#commit"]
  end

  test "emitting an identity frame announces a handle without touching the repo" do
    user = create("alice")
    cursor = RepoStore.max_seq()
    Registry.register(Pesque.EventRegistry, :firehose, [])
    Events.emit_identity(user.did, "new-handle.localhost")

    assert_receive {:firehose_frame, frame}
    {header, body} = decode(frame)

    assert header["t"] == "#identity"
    assert body["did"] == user.did
    assert body["handle"] == "new-handle.localhost"
    assert body["seq"] == cursor + 1

    assert [%Event{did: did}] =
             Repo.all(from e in Event, where: e.seq > ^cursor, order_by: e.seq)

    assert did == user.did

    # The frame announces a handle change; it does not make one. The row is
    # still the account's own, and nothing here is a commit.
    assert Accounts.get_user(user.did).handle == user.handle
  end

  defp create(name) do
    username = unique(name)

    {:ok, user} =
      Accounts.create_account(username <> ".localhost", username <> "@localhost", @password)

    user
  end

  # A call round trip, not the pid, guarantees the genesis commit in
  # handle_continue/2 has already run.
  defp start_repo(user) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    RepoServer.entries(pid)
    pid
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp post(text) do
    %{"$type" => "app.bsky.feed.post", "text" => text, "createdAt" => "2026-01-01T00:00:00.000Z"}
  end
end
