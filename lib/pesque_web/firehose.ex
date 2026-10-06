defmodule PesqueWeb.Firehose do
  @moduledoc """
  The firehose socket. Server-push only: clients never send frames.
  Replays history for the given cursor, then forwards live commit frames.
  """

  @behaviour WebSock

  alias Pesque.CBOR
  alias Pesque.RepoStore

  @impl true
  def init(%{cursor: :invalid}) do
    frame = error_frame("InvalidCursor", "cursor is not a non-negative integer")
    {:stop, :normal, 1000, [{:binary, frame}], %{}}
  end

  def init(%{cursor: cursor}) do
    case replay(cursor) do
      {:ok, frames} ->
        Registry.register(Pesque.EventRegistry, :firehose, [])
        {:push, Enum.map(frames, &{:binary, &1}), %{}}

      {:error, :future_cursor} ->
        frame = error_frame("FutureCursor", "cursor is ahead of the current sequence")
        # Close after the error frame; registering and staying open would keep
        # the socket on the registry and streaming live frames nobody asked for.
        {:stop, :normal, 1000, [{:binary, frame}], %{}}
    end
  end

  @impl true
  def handle_in(_message, state), do: {:ok, state}

  @impl true
  def handle_info({:firehose_frame, frame}, state) do
    {:push, [{:binary, frame}], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  defp replay(nil), do: {:ok, []}

  defp replay(cursor) when is_integer(cursor) do
    if cursor > RepoStore.max_seq() do
      {:error, :future_cursor}
    else
      frames = RepoStore.events_after(cursor)

      oldest = RepoStore.oldest_seq()

      if oldest != nil and cursor < oldest - 1 do
        {:ok,
         [info_frame("OutdatedCursor", "requested cursor predates retained history") | frames]}
      else
        {:ok, frames}
      end
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
