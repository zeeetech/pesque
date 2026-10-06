defmodule PesqueWeb.Firehose do
  @moduledoc """
  The firehose socket. Server-push only: clients never send frames.
  Replays history for the given cursor, then forwards live commit frames.

  The state is `%{replayed_through: seq}` while the socket is still catching
  up and `%{replayed_through: nil}` once it is live: the seq is the last one
  the replay already sent, and nil means nothing can arrive twice any more.
  """

  @behaviour WebSock

  alias Pesque.CBOR
  alias Pesque.RepoStore

  # How much history one connect hands back. The storage layer has a default of
  # the same size, but it is passed explicitly here because the two have to
  # agree for a full page to mean "this is all there was".
  @replay_page_size 10_000

  @impl true
  def init(%{cursor: :invalid}) do
    frame = error_frame("InvalidCursor", "cursor is not a non-negative integer")
    {:stop, :normal, 1000, [{:binary, frame}], %{}}
  end

  def init(%{cursor: cursor}) do
    # Registered before the log is read, not after. RepoServer dispatches to
    # this registry as soon as a commit is written, so a commit landing while
    # the replay query runs would go to no listener at all and would not be in
    # the query result either. What arrives in the window is already sitting in
    # this process mailbox when init/1 returns, so it is handled after the
    # replay was pushed and no self-send or continuation is needed to order it.
    Registry.register(Pesque.EventRegistry, :firehose, [])

    case replay(cursor) do
      {:ok, frames, replayed_through} ->
        {:push, Enum.map(frames, &{:binary, &1}), %{replayed_through: replayed_through}}

      {:error, reason} ->
        close(reason)
    end
  end

  @impl true
  def handle_in(_message, state), do: {:stop, :normal, 1003, state}

  @impl true
  def handle_info({:firehose_frame, frame}, %{replayed_through: nil} = state) do
    {:push, [{:binary, frame}], state}
  end

  # A commit written between the registration and the replay query is in the
  # replay *and* in this mailbox. Its seq is what tells the two apart: anything
  # at or below what the replay carried was already sent, and sending it again
  # hands the consumer the same commit twice. The first frame past the replay
  # closes the window, since a frame that is not one of the replay's cannot be
  # followed by one that is: dispatches leave in commit order per repo, and two
  # repos committing at once only reorder against each other inside the window.
  def handle_info({:firehose_frame, frame}, %{replayed_through: through} = state) do
    case seq_of(frame) do
      # A frame with no readable seq cannot be shown to be one the replay
      # already sent, and dropping it would be the gap this window exists to
      # close.
      nil -> push(frame, %{state | replayed_through: nil})
      seq when seq <= through -> {:ok, state}
      _seq -> push(frame, %{state | replayed_through: nil})
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp push(frame, state), do: {:push, [{:binary, frame}], state}

  defp replay(nil), do: {:ok, [], nil}

  defp replay(cursor) when is_integer(cursor) do
    if cursor > RepoStore.max_seq() do
      {:error, :future_cursor}
    else
      # One frame past the page, so a replay that ran into the cap is visible
      # as one. Without it a consumer too far behind to be served gets the
      # first page of history, goes live, and silently misses everything in
      # between: a full page is a page, not the whole log.
      case RepoStore.events_after(cursor, @replay_page_size + 1) do
        frames when length(frames) > @replay_page_size ->
          {:error, :too_far_behind}

        frames ->
          oldest = RepoStore.oldest_seq()

          # The info frame carries no seq of its own, so what the replay
          # covered is read off the log frames it goes in front of.
          {:ok, replayed(frames, cursor, oldest), replayed_through(frames)}
      end
    end
  end

  defp replayed(frames, cursor, oldest) do
    if oldest != nil and cursor < oldest - 1 do
      [info_frame("OutdatedCursor", "requested cursor predates retained history") | frames]
    else
      frames
    end
  end

  defp replayed_through([]), do: nil
  defp replayed_through(frames), do: seq_of(List.last(frames))

  # Every frame the firehose emits carries its seq in its body, which is what
  # makes the catch-up window decidable without trusting arrival order.
  defp seq_of(frame) do
    {_header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    body["seq"]
  end

  defp close(reason) do
    frame =
      case reason do
        :future_cursor ->
          error_frame("FutureCursor", "cursor is ahead of the current sequence")

        :too_far_behind ->
          # The #info shape rather than an error frame, because that is what the
          # retention branch already answers a lost cursor with: a consumer that
          # resyncs on OutdatedCursor resyncs on this too.
          info_frame(
            "OutdatedCursor",
            "more than #{@replay_page_size} frames of history behind this cursor"
          )
      end

    # The registration happened first, so an error branch has to take it back:
    # otherwise the socket stays on the registry and keeps receiving frames for
    # a consumer that was just told to resync.
    Registry.unregister(Pesque.EventRegistry, :firehose)
    {:stop, :normal, 1000, [{:binary, frame}], %{}}
  end

  defp error_frame(name, message) do
    CBOR.encode(%{"op" => -1}) <> CBOR.encode(%{"error" => name, "message" => message})
  end

  defp info_frame(name, message) do
    CBOR.encode(%{"op" => 1, "t" => "#info"}) <>
      CBOR.encode(%{"name" => name, "message" => message})
  end
end
