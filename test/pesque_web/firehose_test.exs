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

  test "a cursor ahead of the log is refused and leaves nothing registered" do
    seed_events(1, 1)

    assert {:stop, :normal, 1000, [{:binary, frame}], _state} =
             Firehose.init(%{cursor: RepoStore.max_seq() + 1})

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
      refute match?(%{"t" => "#info"}, decode(frame))
    end
  end

  # The registration happens before the replay query, so a commit written in
  # that window is dispatched to this socket as well as written to the log. It
  # has to go out once, not twice, and not never.
  test "a frame the replay already carried is not pushed a second time" do
    alice = create_account("alice")
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

  # Bandit has already inflated and CBOR-decoded anything a client sends, so
  # swallowing it would turn every open socket into a CPU sink for frames the
  # protocol has no use for.
  test "a client frame is refused as unsupported data" do
    state = %{replayed_through: nil}

    assert {:stop, :normal, 1003, ^state} = Firehose.handle_in({"hello", opcode: :text}, state)
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

    :ok
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end
end
