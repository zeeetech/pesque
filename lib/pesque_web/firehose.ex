defmodule PesqueWeb.Firehose do
  @moduledoc """
  The firehose socket. Server-push only: clients never send frames.
  Replays history for the given cursor, then forwards live commit frames.
  """

  @behaviour WebSock

  alias Pesque.{CBOR, RepoStore}

  @impl true
  def init(%{cursor: cursor}) do
    Registry.register(Pesque.EventRegistry, :firehose, [])

    case replay(cursor) do
      {:ok, frames} ->
        {:push, Enum.map(frames, &{:binary, &1}), %{}}

      {:error, :future_cursor} ->
        frame = error_frame("FutureCursor", "cursor is ahead of the current sequence")
        {:push, [{:binary, frame}], %{}}
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
