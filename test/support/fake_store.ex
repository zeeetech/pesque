defmodule Pesque.FakeStore do
  @moduledoc """
  The one store the test doubles read their answers from and record their
  calls into: `Pesque.Migrate.FakeOldPds` and `Pesque.Plc.TestClient`.

  It lives in the application environment, under a single key holding one
  map. Application env is the store because every test that uses these
  doubles runs `async: false`, so there is one move in flight at a time and
  one place for its answers is enough. A move runs in a task of its own, and
  a task reads what the test process wrote here, which a per-process
  dictionary could not offer.

  The store is cleared between tests so nothing bleeds across: the doubles'
  tests clear it where they already do their per-test setup.
  """

  @key :fake_store

  @doc "Writes an answer, or a call the double records, into the store."
  @spec put(atom(), term()) :: term()
  def put(key, value) do
    Application.put_env(:pesque, @key, Map.put(current(), key, value))
    value
  end

  @doc "Reads a key, answering nil when nothing was written for it."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil), do: Map.get(current(), key, default)

  @doc "Empties the store: one key, one delete."
  @spec clear() :: :ok
  def clear, do: Application.delete_env(:pesque, @key)

  defp current, do: Application.get_env(:pesque, @key, %{})
end
