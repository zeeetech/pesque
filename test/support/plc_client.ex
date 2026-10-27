defmodule Pesque.Plc.TestClient do
  @moduledoc """
  A stand-in for `Pesque.Plc.Directory` that never reaches the network.

  `Pesque.Plc` reads its client from `:plc_client`, so a test swaps this in
  and drives submit and resolve through `Pesque.FakeStore`, which a spawned
  move's task reads as well as the process that seeded it.
  """

  alias Pesque.FakeStore

  @doc "Records the last submitted operation and answers the configured result."
  def submit(did, op) do
    FakeStore.put(:plc_last_submit, {did, op})

    case FakeStore.get(:plc_submit_result, :ok) do
      :ok = result ->
        operations = FakeStore.get(:plc_operations, %{})
        FakeStore.put(:plc_operations, Map.put(operations, did, op))
        result

      result ->
        result
    end
  end

  @doc "Answers an explicit resolution override, or resolves a locally submitted operation."
  def resolve(did) do
    case FakeStore.get(:plc_resolve_result, :unset) do
      :unset ->
        case FakeStore.get(:plc_operations, %{}) do
          %{^did => operation} -> {:ok, document(did, operation)}
          _missing -> {:error, :not_found}
        end

      result ->
        result
    end
  end

  defp document(did, operation) do
    services =
      case operation["services"] do
        %{"atproto_pds" => %{"type" => type, "endpoint" => endpoint}} ->
          [%{"id" => "#atproto_pds", "type" => type, "serviceEndpoint" => endpoint}]

        _missing ->
          []
      end

    %{
      "id" => did,
      "alsoKnownAs" => operation["alsoKnownAs"],
      "verificationMethod" => operation["verificationMethods"],
      "service" => services
    }
  end
end
