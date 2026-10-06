defmodule Pesque.RepoSupervisor do
  @moduledoc "Starts and finds the per-repo RepoServer processes."

  use DynamicSupervisor

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_started(did) do
    case Registry.lookup(Pesque.RepoRegistry, did) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Pesque.RepoServer, did}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
          :ignore -> {:error, :ignored}
        end
    end
  end
end
