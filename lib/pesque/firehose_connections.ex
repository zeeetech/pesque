defmodule Pesque.FirehoseConnections do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def admit(address), do: GenServer.call(__MODULE__, {:admit, address})

  @impl true
  def init(_opts), do: {:ok, %{connections: %{}, by_address: %{}, total: 0}}

  @impl true
  def handle_call({:admit, address}, {pid, _tag}, state) do
    cond do
      Map.get(state.by_address, address, 0) >= Pesque.firehose_ip_connection_limit() ->
        {:reply, {:error, :ip_limit}, state}

      state.total >= Pesque.firehose_global_connection_limit() ->
        {:reply, {:error, :global_limit}, state}

      true ->
        ref = Process.monitor(pid)

        next = %{
          state
          | connections: Map.put(state.connections, ref, address),
            by_address: Map.update(state.by_address, address, 1, &(&1 + 1)),
            total: state.total + 1
        }

        {:reply, :ok, next}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.connections, ref) do
      {nil, _connections} ->
        {:noreply, state}

      {address, connections} ->
        by_address =
          case Map.fetch!(state.by_address, address) do
            1 -> Map.delete(state.by_address, address)
            count -> Map.put(state.by_address, address, count - 1)
          end

        {:noreply,
         %{state | connections: connections, by_address: by_address, total: state.total - 1}}
    end
  end
end
