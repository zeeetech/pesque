defmodule Pesque.Migrate.FakeOldPds do
  @moduledoc """
  An old PDS that never reaches the network: canned answers read from
  `Pesque.FakeStore`, and a record of every call.
  """

  @behaviour Pesque.Migrate.OldPds

  alias Pesque.FakeStore

  @impl true
  def create_session(_base_url, handle, _password) do
    record({:create_session, handle})
    FakeStore.get(:fake_create_session, {:error, :not_configured})
  end

  @impl true
  def get_repo(_base_url, _access_jwt, did) do
    record({:get_repo, did})
    {:ok, FakeStore.get(:fake_repo_car, <<>>)}
  end

  @impl true
  def list_blobs(_base_url, _access_jwt, did) do
    record({:list_blobs, did})
    FakeStore.get(:fake_blobs, {:ok, []})
  end

  @impl true
  def get_blob(_base_url, did, cid) do
    record({:get_blob, did, cid})
    FakeStore.get(:fake_blob, {:ok, "blob", "text/plain"})
  end

  @impl true
  def request_plc_signature(_base_url, _access_jwt) do
    record(:request_plc_signature)
    :ok
  end

  @impl true
  def sign_plc_operation(_base_url, _access_jwt, credentials, token) do
    record({:sign_plc_operation, token})
    {:ok, Map.put(credentials, "type", "plc_operation")}
  end

  @impl true
  def deactivate(_base_url, _access_jwt) do
    record(:deactivate)
    :ok
  end

  defp record(call), do: FakeStore.put(:fake_calls, [call | FakeStore.get(:fake_calls, [])])
end
