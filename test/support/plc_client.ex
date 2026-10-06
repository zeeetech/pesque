defmodule Pesque.Plc.TestClient do
  @moduledoc """
  A stand-in for `Pesque.Plc.Directory` that never reaches the network.

  `Pesque.Plc` reads its client from `:plc_client`, so a test swaps this in and
  drives submit and resolve through the process dictionary. The calls are
  synchronous in the process that makes them, so no ETS or Agent is needed.
  """

  @doc "Records the last submitted operation and answers the configured result."
  def submit(did, op) do
    Process.put(:plc_last_submit, {did, op})
    Process.get(:plc_submit_result, :ok)
  end

  @doc "Answers the configured resolution result."
  def resolve(_did), do: Process.get(:plc_resolve_result, {:error, :not_found})
end
