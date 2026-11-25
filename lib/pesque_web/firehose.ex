defmodule PesqueWeb.Firehose do
  @moduledoc """
  The firehose socket. Server-push only: clients never send frames.
  Replays history for the given cursor, then forwards live event frames.

  The state is `%{replayed_through: seq}` while the socket is still catching
  up and `%{replayed_through: nil}` once it is live: the seq is the last one
  covered by replay (or the requested cursor when it loaded no events), and nil
  means nothing can arrive twice any more.
  """

  @behaviour WebSock

  alias Pesque.CBOR
  alias Pesque.Commit
  alias Pesque.RepoStore

  # The event-count cap is checked before the bounded payload query.
  @replay_page_size 10_000

  @impl true
  def init(%{cursor: :invalid}) do
    frame = error_frame("InvalidCursor", "cursor is not a non-negative integer")
    {:stop, :normal, 1000, [{:binary, frame}], %{}}
  end

  def init(%{cursor: cursor}) do
    # Register before reading the log. A commit arriving while the replay query
    # runs may be in both the bounded query and this process mailbox; its seq
    # lets handle_info/2 discard the copy the replay already sent.
    Registry.register(Pesque.EventRegistry, :firehose, [])
    Process.monitor(Pesque.Events)

    case replay(cursor) do
      {:ok, frames, replayed_through} ->
        {:push, Enum.map(frames, &{:binary, &1}), %{replayed_through: replayed_through}}

      {:error, reason} ->
        close(reason)
    end
  end

  @impl true
  # Event Stream is server-push; the protocol requires ignoring client frames.
  def handle_in(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:firehose_frame, frame}, state) do
    case frame_seq(frame) do
      {:ok, seq} ->
        handle_frame(frame, seq, state)

      {:error, :frame_too_large} ->
        {:stop, :normal, 1009, state}

      {:error, :invalid_frame} ->
        {:stop, :normal, 1002, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:stop, :normal, 1012, state}

  def handle_info(_message, state), do: {:ok, state}

  defp handle_frame(frame, _seq, %{replayed_through: nil} = state), do: push(frame, state)

  # A commit written between registration and the replay query can be in the
  # replay and in this mailbox. The seq tells the two apart without relying on
  # dispatcher arrival order.
  defp handle_frame(frame, seq, %{replayed_through: through} = state) do
    if seq <= through do
      {:ok, state}
    else
      push(frame, %{state | replayed_through: nil})
    end
  end

  defp push(frame, state), do: {:push, [{:binary, frame}], state}

  defp replay(nil), do: {:ok, [], nil}

  defp replay(cursor) when is_integer(cursor) do
    target_seq = RepoStore.event_cursor()

    if cursor > target_seq do
      {:error, :future_cursor}
    else
      {count, bytes} = RepoStore.event_stats(cursor, target_seq)

      if count > @replay_page_size or bytes > Pesque.firehose_replay_max_bytes() do
        {:error, :too_far_behind}
      else
        rows = RepoStore.event_rows_between(cursor, target_seq, @replay_page_size)

        case validate_replay_rows(rows) do
          {:ok, frames} ->
            oldest = RepoStore.oldest_seq()
            payloads = Enum.map(frames, &elem(&1, 1))

            # The info frame carries no seq of its own, so what the replay
            # covered is read off the log frames it goes in front of.
            {:ok, replayed(payloads, cursor, oldest, target_seq),
             replayed_through(frames, cursor)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp validate_replay_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn {seq, frame}, {:ok, acc} ->
      case frame_seq(frame) do
        {:ok, ^seq} -> {:cont, {:ok, [{seq, frame} | acc]}}
        {:ok, _other_seq} -> {:halt, {:error, :invalid_frame}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, frames} -> {:ok, Enum.reverse(frames)}
      error -> error
    end
  end

  defp replayed(frames, cursor, oldest, target_seq) do
    if (oldest == nil and cursor < target_seq) or
         (oldest != nil and cursor < oldest - 1) do
      [info_frame("OutdatedCursor", "requested cursor predates retained history") | frames]
    else
      frames
    end
  end

  defp replayed_through([], cursor), do: cursor
  defp replayed_through(frames, _cursor), do: frames |> List.last() |> elem(0)

  defp frame_seq(frame) when is_binary(frame) do
    if byte_size(frame) > Commit.max_frame_bytes() do
      {:error, :frame_too_large}
    else
      try do
        with {%{"op" => 1, "t" => type}, rest} when is_binary(type) <- CBOR.decode(frame),
             {%{"seq" => seq}, ""} when is_integer(seq) and seq >= 0 <- CBOR.decode(rest) do
          {:ok, seq}
        else
          _other -> {:error, :invalid_frame}
        end
      rescue
        _exception -> {:error, :invalid_frame}
      catch
        _kind, _reason -> {:error, :invalid_frame}
      end
    end
  end

  defp frame_seq(_frame), do: {:error, :invalid_frame}

  defp close(reason) do
    # The registration happened first, so an error branch has to take it back:
    # otherwise the socket stays on the registry and keeps receiving frames for
    # a consumer that was just told to leave.
    Registry.unregister(Pesque.EventRegistry, :firehose)

    if reason in [:frame_too_large, :invalid_frame] do
      code = if reason == :frame_too_large, do: 1009, else: 1002
      {:stop, :normal, code, [], %{}}
    else
      frame =
        case reason do
          :future_cursor ->
            error_frame("FutureCursor", "cursor is ahead of the current sequence")

          :too_far_behind ->
            info_frame(
              "OutdatedCursor",
              "replay exceeds #{@replay_page_size} events or #{Pesque.firehose_replay_max_bytes()} bytes"
            )
        end

      {:stop, :normal, 1000, [{:binary, frame}], %{}}
    end
  end

  defp error_frame(name, message) do
    CBOR.encode(%{"op" => -1}) <> CBOR.encode(%{"error" => name, "message" => message})
  end

  defp info_frame(name, message) do
    CBOR.encode(%{"op" => 1, "t" => "#info"}) <>
      CBOR.encode(%{"name" => name, "message" => message})
  end
end
