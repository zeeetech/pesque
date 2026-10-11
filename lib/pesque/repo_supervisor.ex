defmodule Pesque.RepoSupervisor do
  @moduledoc "Starts and finds the per-repo RepoServer processes."

  use DynamicSupervisor

  # The Registry reaps a dead process's entry asynchronously from its DOWN,
  # so for a moment after a stop (or crash) the entry still names a pid that
  # is gone. Both wait this long, in 1 ms steps, for the Registry to catch up.
  @registry_grace_ms 2_000

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  The pid of the running `RepoServer` for `did`, starting one if none runs.

  The answer is alive at the moment it is returned: an entry naming a dead
  pid is a Registry gap, waited out rather than handed to a caller whose
  next call would fail with `:noproc`.
  """
  def ensure_started(did), do: ensure_started(did, deadline())

  defp ensure_started(did, deadline) do
    case Registry.lookup(Pesque.RepoRegistry, did) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: await_registry(did, deadline)

      [] ->
        start(did, deadline)
    end
  end

  defp start(did, deadline) do
    case DynamicSupervisor.start_child(__MODULE__, {Pesque.RepoServer, did}) do
      {:ok, pid} ->
        {:ok, pid}

      # The via-registration collided with the stale entry, which still names
      # the dead pid; wait for the Registry to drop it, then try again.
      {:error, {:already_started, pid}} ->
        if Process.alive?(pid), do: {:ok, pid}, else: await_registry(did, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_registry(did, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :unavailable}
    else
      Process.sleep(1)
      ensure_started(did, deadline)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @registry_grace_ms
end
