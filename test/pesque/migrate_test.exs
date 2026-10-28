defmodule Pesque.MigrateTest do
  @moduledoc """
  The migration orchestration, with the old PDS faked.

  The fake client records every call and answers from `Pesque.FakeStore`,
  so the whole move runs without a network. The PLC directory is
  `Pesque.Plc.TestClient`, driven the same way. The account, repo and blobs are
  real, so the new-server half is exercised as it runs.
  """

  use Pesque.DataCase, async: false

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.Migrate
  alias Pesque.RepoStore

  @password "hunter2hunter2"

  setup do
    restore_env()
    Application.put_env(:pesque, :mode, :multi)
    Application.put_env(:pesque, :identity, :plc)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_submit_result, :ok)
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
    assert :request_plc_signature in calls()
    assert {:sign_plc_operation, "email-code"} in calls()
  end

  # The old PDS deactivates the account as the last step of the move, and its
  # #account event is the last one for the DID that is not ours. The move
  # re-announces here after it, so a consumer that only applies the sequence
  # ends with the account active rather than deactivated.
  test "the last account event for the DID is this PDS's activation" do
    did = old_did()
    handle = unique("heidi") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok = run(handle)

    {_header, last} = did |> account_events() |> List.last()

    assert last["active"]
    refute last["status"]
  end

  # The spec pairs the identity update with an #identity event, so a consumer
  # keyed on the handle moves it to this server.
  test "the identity update is announced with an #identity frame" do
    did = old_did()
    handle = unique("ivan") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok = run(handle)

    assert {_header, body} = did |> identity_events() |> List.last()
    assert body["handle"] == handle
  end

  test "a supplied PLC token is used instead of asking for a new code" do
    did = old_did()
    handle = unique("dave") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok = run(handle, plc_token: "the-code")

    assert {:sign_plc_operation, "the-code"} in calls()
    refute :request_plc_signature in calls()
  end

  test "request_plc_code emails a code without moving anything" do
    did = old_did()
    handle = unique("erin") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok =
             Migrate.request_plc_code(
               old_pds: "https://old.example.com",
               handle: handle,
               password: @password,
               client: Pesque.Migrate.FakeOldPds
             )

    assert :request_plc_signature in calls()
    refute {:get_repo, did} in calls()
    refute Accounts.get_user(did)
  end

  test "reports progress while it imports blobs" do
    did = old_did()
    handle = unique("frank") <> ".localhost"

    configure_happy_path(did, handle)

    test_pid = self()

    assert :ok =
             Migrate.run(
               old_pds: "https://old.example.com",
               handle: handle,
               email: handle <> "@localhost",
               password: @password,
               client: Pesque.Migrate.FakeOldPds,
               prompt: fn _prompt -> "email-code" end,
               log: fn line -> send(test_pid, {:progress, line}) end
             )

    lines = collected()
    assert "importing 1 blob for #{did}" in lines
    assert "imported 1 of 1 blob" in lines
    assert "imported 1 blob for #{did}" in lines
  end

  test "a re-run keeps blobs already stored instead of fetching them again" do
    did = old_did()
    handle = unique("grace") <> ".localhost"

    configure_happy_path(did, handle)

    assert :ok = run(handle)
    assert RepoStore.get_blob(did, blob_cid())

    Pesque.FakeStore.put(:fake_calls, [])

    assert :ok = run(handle)

    refute Enum.any?(calls(), &match?({:get_blob, _did, _cid}, &1)),
           "a blob already on disk was fetched again"
  end

  test "a create_session failure returns the error and creates no account" do
    did = old_did()
    handle = unique("bob") <> ".localhost"
    Pesque.FakeStore.put(:fake_create_session, {:error, :invalid_credentials})

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

  defp run(handle, extra \\ []) do
    Migrate.run(
      [
        old_pds: "https://old.example.com",
        handle: handle,
        email: handle <> "@localhost",
        password: @password,
        client: Pesque.Migrate.FakeOldPds,
        prompt: fn _prompt -> "email-code" end,
        log: fn _line -> :ok end
      ] ++ extra
    )
  end

  defp configure_happy_path(did, handle) do
    Pesque.FakeStore.put(
      :fake_create_session,
      {:ok, %{access_jwt: "access", did: did, handle: handle}}
    )

    Pesque.FakeStore.put(:fake_repo_car, source_car())
    Pesque.FakeStore.put(:fake_blobs, {:ok, [blob_cid()]})
    Pesque.FakeStore.put(:fake_blob, {:ok, "blob bytes", "text/plain"})
    Pesque.FakeStore.put(:plc_resolve_result, {:ok, pds_document(did)})
  end

  # The CID the fake's bytes hash to, so a re-run finds the stored blob under
  # the same CID listBlobs named, as real content addressing guarantees.
  defp blob_cid, do: CID.to_string(CID.from_data("blob bytes", CID.raw()))

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

  defp calls, do: Pesque.FakeStore.get(:fake_calls, [])

  defp collected(acc \\ []) do
    receive do
      {:progress, line} -> collected([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp account_events(did), do: events_for(did, "#account")
  defp identity_events(did), do: events_for(did, "#identity")

  defp events_for(did, type) do
    RepoStore.events_after(0)
    |> Enum.map(&decode/1)
    |> Enum.filter(fn {header, body} -> header["t"] == type and body["did"] == did end)
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end

  defp restore_env do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each([:mode, :identity, :plc_client], &Application.delete_env(:pesque, &1))
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)
  end
end
