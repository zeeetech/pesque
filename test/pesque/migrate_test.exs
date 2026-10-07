defmodule Pesque.MigrateTest do
  @moduledoc """
  The migration orchestration, with the old PDS faked.

  The fake client records every call and answers from the process dictionary,
  so the whole move runs without a network. The PLC directory is
  `Pesque.Plc.TestClient`, driven the same way. The account, repo and blobs are
  real, so the new-server half is exercised as it runs.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.Migrate
  alias Pesque.RepoStore

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    restore_env()
    Application.put_env(:pesque, :mode, :path_multi)
    Application.put_env(:pesque, :identity, :plc)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Process.put(:plc_submit_result, :ok)
    :ok
  end

  test "moves an account: creates, imports, submits, activates, deactivates" do
    did = old_did()
    handle = unique("alice") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok = run(handle)

    user = Accounts.get_user(did)
    assert user.active
    assert RepoStore.get_meta("commit:" <> did)

    cid = CID.to_string(CID.from_data("blob bytes", CID.raw()))
    assert RepoStore.get_blob(did, cid)

    assert :deactivate in calls()
    assert {:get_repo, did} in calls()
    assert {:list_blobs, did} in calls()
  end

  test "a create_session failure returns the error and creates no account" do
    did = old_did()
    handle = unique("bob") <> ".localhost"
    Process.put(:fake_create_session, {:error, :invalid_credentials})

    assert {:error, :invalid_credentials} = run(handle)
    refute Accounts.get_user(did)
  end

  test "a re-run with the account already present does not fail at account creation" do
    did = old_did()
    handle = unique("carol") <> ".localhost"

    assert {:ok, _user} =
             Accounts.create_imported_account(handle, "carol@localhost", @password, did)

    configure_happy_path(did, handle)

    assert :ok = run(handle)
    assert Accounts.get_user(did).active
  end

  defp run(handle) do
    Migrate.run(
      old_pds: "https://old.example.com",
      handle: handle,
      email: handle <> "@localhost",
      password: @password,
      client: Pesque.MigrateTest.FakeOldPds,
      prompt: fn _prompt -> "email-code" end,
      log: fn _line -> :ok end
    )
  end

  defp configure_happy_path(did, handle) do
    Process.put(:fake_create_session, {:ok, %{access_jwt: "access", did: did, handle: handle}})
    Process.put(:fake_repo_car, source_car())
    Process.put(:fake_blobs, {:ok, ["bafkreiblob"]})
    Process.put(:fake_blob, {:ok, "blob bytes", "text/plain"})
    Process.put(:plc_resolve_result, {:ok, pds_document(did)})
  end

  # A real CAR, built from a throwaway account's genesis repo, so
  # Car.decode_repo and RepoImport.persist_import run against bytes a repo
  # actually exports.
  defp source_car do
    {:ok, user} = Accounts.create_account("source.localhost", "source@localhost", @password)
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    Pesque.RepoServer.entries(pid)

    commit = RepoStore.get_meta("commit:" <> user.did)

    blocks =
      user.did
      |> RepoStore.blocks_for()
      |> Map.new(fn block -> {CID.parse(block.cid), block.data} end)

    Car.encode([CID.parse(commit)], blocks)
  end

  defp pds_document(did) do
    %{
      "service" => [
        %{
          "id" => did <> "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => Pesque.service_endpoint()
        }
      ]
    }
  end

  defp old_did, do: "did:plc:" <> Pesque.Base32.encode(:crypto.strong_rand_bytes(15))

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp calls, do: Process.get(:fake_calls, [])

  defp restore_env do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each([:mode, :identity, :plc_client], &Application.delete_env(:pesque, &1))
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)
  end
end

defmodule Pesque.MigrateTest.FakeOldPds do
  @moduledoc """
  An old PDS that never reaches the network: canned answers read from the
  process dictionary, and a record of every call.
  """

  @behaviour Pesque.Migrate.OldPds

  @impl true
  def create_session(_base_url, handle, _password) do
    record({:create_session, handle})
    Process.get(:fake_create_session, {:error, :not_configured})
  end

  @impl true
  def get_repo(_base_url, _access_jwt, did) do
    record({:get_repo, did})
    {:ok, Process.get(:fake_repo_car, <<>>)}
  end

  @impl true
  def list_blobs(_base_url, _access_jwt, did) do
    record({:list_blobs, did})
    Process.get(:fake_blobs, {:ok, []})
  end

  @impl true
  def get_blob(_base_url, did, cid) do
    record({:get_blob, did, cid})
    Process.get(:fake_blob, {:ok, "blob", "text/plain"})
  end

  @impl true
  def request_plc_signature(_base_url, _access_jwt) do
    record(:request_plc_signature)
    :ok
  end

  @impl true
  def sign_plc_operation(_base_url, _access_jwt, credentials, _token) do
    record(:sign_plc_operation)
    {:ok, Map.put(credentials, "type", "plc_operation")}
  end

  @impl true
  def deactivate(_base_url, _access_jwt) do
    record(:deactivate)
    :ok
  end

  defp record(call), do: Process.put(:fake_calls, [call | Process.get(:fake_calls, [])])
end
