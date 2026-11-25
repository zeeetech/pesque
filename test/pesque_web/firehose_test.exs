defmodule PesqueWeb.FirehoseTest do
  @moduledoc """
  What a consumer is told when the socket cannot serve its cursor: too far
  behind to replay in one page, ahead of the log, or predating what retention
  kept. And the two ends of an ordinary connect, the replay and the live frames
  after it, including the commit whose dispatch lands while the replay is being
  read.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.CBOR
  alias Pesque.EventFrames
  alias Pesque.Events
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event
  alias PesqueWeb.Firehose

  @page_size 10_000
  @did "did:web:localhost"

  # The log is emptied before each test, and that is load bearing rather than
  # tidiness.
  #
  # One SQLite file backs the whole suite, and the event table's primary key is
  # the seq every firehose assertion below is written against: page boundaries,
  # the retention edge at oldest - 1, the replay watermark. Anything that
  # commits outside the sandbox leaves rows nothing rolls back, and the next
  # seed from seq 1 then dies on the primary key with a UNIQUE constraint
  # failure that reads as a firehose bug rather than a dirty fixture.
  #
  # The delete runs inside each test's own sandbox transaction, so it is undone
  # with everything else this file writes and cannot affect another test.
  setup do
    Repo.delete_all(Event)
    :ok
  end

  # A page that is the whole log is a replay, not a truncation. Only a cursor
  # with something past the page is too far behind, and reading the first case
  # as the second would put every consumer sitting exactly one page back into a
  # resync it does not need.
  test "a replay that is exactly one page long is served" do
    seed_events(1, @page_size)

    assert {:push, frames, %{replayed_through: through}} = Firehose.init(%{cursor: 0})

    assert length(frames) == @page_size
    assert through == @page_size
  end

  # Serving the first page of a longer log would look like a complete replay:
  # the consumer goes live at the cap and hears nothing about the commits in
  # between, with no signal to resync on. OutdatedCursor is that signal, and it
  # is what the retention branch already answers with.
  test "a cursor behind more than a page is told to resync" do
    seed_events(1, @page_size + 1)

    assert {:stop, :normal, 1000, [{:binary, frame}], _state} = Firehose.init(%{cursor: 0})

    assert {%{"op" => 1, "t" => "#info"}, %{"name" => "OutdatedCursor"}} = decode(frame)

    # The socket registered itself before reading the log, so closing has to
    # take the registration back rather than leave it collecting frames for a
    # consumer that was just told to leave.
    assert Registry.lookup(Pesque.EventRegistry, :firehose) == []
  end

  test "a replay over the byte budget is refused before payloads are decoded" do
    replay_byte_budget(1)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    Repo.insert_all(Event, [%{seq: 1, did: @did, payload: <<0, 1>>, inserted_at: now}])
    set_event_cursor(1)

    assert {:stop, :normal, 1000, [{:binary, frame}], _state} = Firehose.init(%{cursor: 0})

    assert {%{"t" => "#info"}, %{"name" => "OutdatedCursor"}} = decode(frame)
    assert Registry.lookup(Pesque.EventRegistry, :firehose) == []
  end

  test "a replay at the exact byte budget is served and one byte over is outdated" do
    frame = EventFrames.identity(1, @did, "seed.localhost")
    frame_bytes = byte_size(frame)
    replay_byte_budget(frame_bytes)

    now = DateTime.truncate(DateTime.utc_now(), :second)
    Repo.insert_all(Event, [%{seq: 1, did: @did, payload: frame, inserted_at: now}])
    set_event_cursor(1)

    assert {:push, [{:binary, ^frame}], %{replayed_through: 1}} =
             Firehose.init(%{cursor: 0})

    Registry.unregister(Pesque.EventRegistry, :firehose)
    Application.put_env(:pesque, :firehose_replay_max_bytes, frame_bytes - 1)

    assert {:stop, :normal, 1000, [{:binary, info}], _state} = Firehose.init(%{cursor: 0})
    assert {%{"t" => "#info"}, %{"name" => "OutdatedCursor"}} = decode(info)
  end

  test "an empty retained log behind the durable cursor reports OutdatedCursor" do
    RepoStore.put_meta!("event:seq", "5")

    assert {:push, [{:binary, info}], %{replayed_through: 2}} =
             Firehose.init(%{cursor: 2})

    assert {%{"t" => "#info"}, %{"name" => "OutdatedCursor"}} = decode(info)
  end

  test "an empty replay at the durable cursor keeps its numeric watermark" do
    RepoStore.put_meta!("event:seq", "5")

    assert {:push, [], %{replayed_through: 5}} = Firehose.init(%{cursor: 5})
  end

  test "a cursor ahead of the log is refused and leaves nothing registered" do
    seed_events(1, 1)

    assert {:stop, :normal, 1000, [{:binary, frame}], _state} =
             Firehose.init(%{cursor: RepoStore.event_cursor() + 1})

    assert {%{"op" => -1}, %{"error" => "FutureCursor"}} = decode(frame)
    assert Registry.lookup(Pesque.EventRegistry, :firehose) == []
  end

  test "a cursor predating retention gets the info frame ahead of what is left" do
    seed_events(5, 2)

    assert {:push, [{:binary, info} | rest], %{replayed_through: 6}} =
             Firehose.init(%{cursor: 0})

    assert {%{"t" => "#info"}, %{"name" => "OutdatedCursor"}} = decode(info)
    assert length(rest) == 2
  end

  test "a cursor at the edge of retention is served without a warning" do
    seed_events(5, 2)

    assert {:push, frames, _state} = Firehose.init(%{cursor: 4})

    assert length(frames) == 2

    # No #info in any of them, which is the point: oldest - 1 is still
    # serviceable and must not be told to resync.
    for {_kind, frame} <- frames do
      refute match?({%{"t" => "#info"}, _body}, decode(frame))
    end
  end

  test "an oversized live frame is not broadcast or pushed" do
    state = %{replayed_through: nil}
    frame = :binary.copy(<<0>>, Pesque.Commit.max_frame_bytes() + 1)

    Registry.register(Pesque.EventRegistry, :firehose, [])
    assert {:error, :frame_too_large} = Events.broadcast(frame)
    refute_receive {:firehose_frame, _frame}

    assert {:stop, :normal, 1009, ^state} = Firehose.handle_info({:firehose_frame, frame}, state)

    Registry.unregister(Pesque.EventRegistry, :firehose)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    Repo.insert_all(Event, [%{seq: 1, did: @did, payload: frame, inserted_at: now}])
    set_event_cursor(1)

    assert {:stop, :normal, 1009, [], _state} = Firehose.init(%{cursor: 0})
  end

  test "an invalid live frame closes the socket without being pushed" do
    state = %{replayed_through: nil}

    assert {:stop, :normal, 1002, ^state} =
             Firehose.handle_info({:firehose_frame, <<0xFF>>}, state)
  end

  test "an invalid stored frame closes the socket without being pushed" do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    Repo.insert_all(Event, [%{seq: 1, did: @did, payload: <<0xFF>>, inserted_at: now}])
    set_event_cursor(1)

    assert {:stop, :normal, 1002, [], _state} = Firehose.init(%{cursor: 0})
    assert Registry.lookup(Pesque.EventRegistry, :firehose) == []
  end

  # The registration happens before the replay query, so a commit written in
  # that window is dispatched to this socket as well as written to the log. It
  # has to go out once, not twice, and not never.
  test "a frame the replay already carried is not pushed a second time" do
    alice = insert_repo_account("alice")
    cursor = RepoStore.max_seq()
    Events.emit_identity(alice.did, alice.handle)

    assert {:push, [{:binary, replayed} | _], state} = Firehose.init(%{cursor: cursor})
    assert {%{"t" => "#identity"}, %{"seq" => seq}} = decode(replayed)

    assert {:ok, ^state} = Firehose.handle_info({:firehose_frame, replayed}, state)

    Events.emit_identity(alice.did, "moved.localhost")
    assert_receive {:firehose_frame, live}

    # Past the replay every frame is new, so it goes out and the catch-up window
    # closes: live frames stop being decoded to look for a duplicate.
    assert {:push, [{:binary, ^live}], live_state} =
             Firehose.handle_info({:firehose_frame, live}, state)

    assert live_state == %{replayed_through: nil}

    assert {:push, [{:binary, ^live}], ^live_state} =
             Firehose.handle_info({:firehose_frame, live}, live_state)

    assert seq == cursor + 1
  end

  test "live frames from concurrent DIDs follow persisted seq order" do
    set_event_cursor(0)
    restart_dispatcher()

    alice = "did:web:alice.example"
    bob = "did:web:bob.example"
    first = EventFrames.identity(1, alice, "alice.example")
    second = EventFrames.identity(2, bob, "bob.example")
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all(Event, [
      %{seq: 1, did: alice, payload: first, inserted_at: now},
      %{seq: 2, did: bob, payload: second, inserted_at: now}
    ])

    set_event_cursor(2)

    Registry.register(Pesque.EventRegistry, :firehose, [])

    # The later writer reaches the dispatcher first. It must drain the rows,
    # rather than forwarding notifications in their arrival order.
    assert :ok = Events.broadcast(second)
    assert :ok = Events.broadcast(first)

    assert_receive {:firehose_frame, delivered_first}
    assert_receive {:firehose_frame, delivered_second}

    assert [field(delivered_first, "seq"), field(delivered_second, "seq")] == [1, 2]
    assert [field(delivered_first, "did"), field(delivered_second, "did")] == [alice, bob]
  end

  test "a stale drain target does not rewind the live watermark" do
    set_event_cursor(0)
    restart_dispatcher()
    seed_events(1, 2)
    Registry.register(Pesque.EventRegistry, :firehose, [])

    assert :ok = GenServer.call(Pesque.Events, {:drain, 2})
    assert_receive {:firehose_frame, first}
    assert_receive {:firehose_frame, second}
    assert [field(first, "seq"), field(second, "seq")] == [1, 2]

    assert :ok = GenServer.call(Pesque.Events, {:drain, 1})
    assert :ok = GenServer.call(Pesque.Events, {:drain, 2})
    refute_receive {:firehose_frame, _frame}, 0
  end

  test "dispatcher restart does not replay retained history" do
    seed_events(1, 2)
    Registry.register(Pesque.EventRegistry, :firehose, [])

    restart_dispatcher()

    refute_receive {:firehose_frame, _frame}, 0
  end

  test "a connected socket closes so it can replay after dispatcher restart" do
    events_pid = Process.whereis(Pesque.Events)
    assert is_pid(events_pid)
    assert Process.alive?(events_pid)
    assert {:push, [], state} = Firehose.init(%{cursor: nil})

    on_exit(fn ->
      if is_nil(Process.whereis(Pesque.Events)) do
        Supervisor.restart_child(Pesque.Supervisor, Pesque.Events)
      end
    end)

    :ok = Supervisor.terminate_child(Pesque.Supervisor, Pesque.Events)
    assert_receive down = {:DOWN, _ref, :process, {Pesque.Events, _node}, _reason}

    result = Firehose.handle_info(down, state)
    Registry.unregister(Pesque.EventRegistry, :firehose)
    {:ok, _pid} = Supervisor.restart_child(Pesque.Supervisor, Pesque.Events)

    assert {:stop, :normal, 1012, ^state} = result
  end

  test "a client frame is ignored" do
    state = %{replayed_through: nil}

    assert {:ok, ^state} = Firehose.handle_in({"hello", opcode: :text}, state)
  end

  defp seed_events(first_seq, count) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    for batch <- Enum.chunk_every(first_seq..(first_seq + count - 1), 500) do
      Repo.insert_all(
        Event,
        Enum.map(batch, fn seq ->
          %{
            seq: seq,
            did: @did,
            payload: EventFrames.identity(seq, @did, "seed.localhost"),
            inserted_at: now
          }
        end)
      )
    end

    set_event_cursor(first_seq + count - 1)
    :ok
  end

  defp set_event_cursor(seq), do: RepoStore.put_meta!("event:seq", Integer.to_string(seq))

  defp replay_byte_budget(bytes) do
    previous = Application.get_env(:pesque, :firehose_replay_max_bytes)
    Application.put_env(:pesque, :firehose_replay_max_bytes, bytes)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:pesque, :firehose_replay_max_bytes)
      else
        Application.put_env(:pesque, :firehose_replay_max_bytes, previous)
      end
    end)
  end

  defp restart_dispatcher do
    :ok = Supervisor.terminate_child(Pesque.Supervisor, Pesque.Events)
    {:ok, _pid} = Supervisor.restart_child(Pesque.Supervisor, Pesque.Events)
    :ok
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end

  defp field(frame, key), do: frame |> decode() |> elem(1) |> Map.fetch!(key)
end
