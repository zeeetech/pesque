defmodule PesqueWeb.PlcAccountTest do
  @moduledoc """
  Accounts minted under PDS_IDENTITY=plc, driven through the same ConnCase
  helpers as every other account. The directory is Pesque.Plc.TestClient, so
  nothing here reaches plc.directory.
  """

  use PesqueWeb.ConnCase, async: false

  import Bitwise

  alias Pesque.Accounts
  alias Pesque.Keys
  alias Pesque.Plc
  alias Pesque.Plc.Keys, as: PlcKeys
  alias Pesque.Plc.Operation
  alias Pesque.Storage

  @password "hunter2hunter2"

  setup do
    put_identity(:plc)
    put_client(Pesque.Plc.TestClient)
    :ok
  end

  test "an account created under plc gets a did:plc did and a stored rotation key" do
    user = create_account("alice")

    assert String.starts_with?(user.did, "did:plc:")
    assert String.length(user.did) == 32
    assert user.plc_operation

    genesis = JSON.decode!(user.plc_operation)
    assert genesis["type"] == "plc_operation"
    assert genesis["prev"] == nil
    assert Operation.did_for(genesis) == user.did

    assert File.exists?(PlcKeys.rotation_path(user.did))
    assert File.exists?(Keys.path(user.did))
    refute PlcKeys.rotation_path(user.did) == Keys.path(user.did)
  end

  test "the rotation key is 0600 inside the key directory" do
    user = create_account("alice")

    {:ok, %File.Stat{mode: mode}} = File.stat(PlcKeys.rotation_path(user.did))
    assert band(mode, 0o777) == 0o600
  end

  test "a directory submission failure leaves no account and no keys" do
    Process.put(:plc_submit_result, {:error, :plc_unreachable})

    handle = unique("ghost") <> ".localhost"
    before = File.ls!(Storage.keys_dir())

    assert {:error, :plc_unreachable} =
             Accounts.create_account(handle, unique("ghost") <> "@localhost", @password)

    assert Accounts.resolve_handle(handle) == {:error, :not_found}
    assert File.ls!(Storage.keys_dir()) == before
  end

  test "a handle change points the new op at the previous op's CID" do
    user = create_account("alice")
    genesis = JSON.decode!(user.plc_operation)
    fresh = unique("renamed") <> ".localhost"

    assert {:ok, updated} = Accounts.update_handle(user, fresh)

    assert updated.handle == fresh
    assert updated.did == user.did

    op = JSON.decode!(updated.plc_operation)
    assert op["prev"] == Operation.cid(genesis)
    assert op["alsoKnownAs"] == ["at://" <> fresh]
    assert op["rotationKeys"] == genesis["rotationKeys"]
  end

  test "activation is refused when the document points at another server" do
    user = create_account("alice")
    {:ok, _} = Accounts.deactivate_account(user)

    Process.put(:plc_resolve_result, {:ok, document("https://elsewhere.example")})

    assert {:error, :pds_mismatch} = Accounts.activate_account(Accounts.get_user(user.did))
    refute Accounts.repo_active?(user.did)
  end

  test "activation proceeds when the document points at this server" do
    user = create_account("alice")
    {:ok, _} = Accounts.deactivate_account(user)

    endpoint = Pesque.service_endpoint()
    Process.put(:plc_resolve_result, {:ok, document(endpoint)})

    assert {:ok, did} = Accounts.activate_account(Accounts.get_user(user.did))
    assert did == user.did
    assert Accounts.repo_active?(user.did)
  end

  test "the well-known atproto-did serves the stored did:plc unchanged" do
    user = create_account("alice")

    conn = atproto_did(user.handle)

    assert conn.status == 200
    assert conn.resp_body == user.did
  end

  test "checkAccountStatus and getRepoStatus answer for a did:plc account" do
    user = create_account("alice")

    status =
      xrpc_get("/xrpc/com.atproto.server.checkAccountStatus?did=#{enc(user.did)}")
      |> json_body()

    assert status["validDid"]
    assert status["activated"]

    repo =
      xrpc_get("/xrpc/com.atproto.sync.getRepoStatus?did=#{enc(user.did)}")
      |> json_body()

    assert repo["did"] == user.did
    assert repo["active"]
  end

  test "web identity is unchanged: did:web and no plc operation" do
    put_identity(:web)

    refute Plc.enabled?()

    user = create_account("webuser")

    assert String.starts_with?(user.did, "did:web:")
    assert user.plc_operation == nil
    refute File.exists?(PlcKeys.rotation_path(user.did))
  end

  defp document(endpoint) do
    %{
      "id" => "did:plc:whatever",
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => endpoint
        }
      ]
    }
  end

  defp atproto_did(host) do
    %Plug.Conn{build_conn() | host: host}
    |> dispatch(PesqueWeb.Endpoint, :get, "/.well-known/atproto-did", nil)
  end

  defp json_body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp put_identity(identity) do
    previous = Application.get_env(:pesque, :identity)

    on_exit(fn -> Application.put_env(:pesque, :identity, previous) end)

    Application.put_env(:pesque, :identity, identity)
    :ok
  end

  defp put_client(module) do
    previous = Application.get_env(:pesque, :plc_client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pesque, :plc_client, previous),
        else: Application.delete_env(:pesque, :plc_client)
    end)

    Application.put_env(:pesque, :plc_client, module)
    :ok
  end
end
