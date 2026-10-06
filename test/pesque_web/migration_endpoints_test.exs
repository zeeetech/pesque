defmodule PesqueWeb.MigrationEndpointsTest do
  @moduledoc """
  The identity half of an account migration: the credentials this server
  recommends, and submitting the operation the old PDS signed.

  The PLC directory is an injected fake, so nothing here reaches the network.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.Did
  alias Pesque.Keys
  alias Pesque.Plc.Keys, as: PlcKeys
  alias Pesque.Secp256k1

  @recommended_path "/xrpc/com.atproto.identity.getRecommendedDidCredentials"
  @submit_path "/xrpc/com.atproto.identity.submitPlcOperation"

  describe "getRecommendedDidCredentials" do
    setup do
      put_identity(:plc)
      put_env(:plc_client, Pesque.Plc.TestClient)
      :ok
    end

    test "a did:plc account gets this server, its key, and a rotation key" do
      user = create_account("alice")

      body = @recommended_path |> xrpc_get(token(user)) |> json_body()

      assert body["services"]["atproto_pds"]["endpoint"] == Pesque.base_url()
      assert body["services"]["atproto_pds"]["type"] == "AtprotoPersonalDataServer"
      assert body["alsoKnownAs"] == ["at://" <> user.handle]
      assert body["verificationMethods"]["atproto"] == account_key_did(user)
      assert [rotation_key] = body["rotationKeys"]
      assert String.starts_with?(rotation_key, "did:key:")
      assert File.exists?(PlcKeys.rotation_path(user.did))
    end

    test "a did:web account has no rotation key" do
      put_identity(:web)
      user = create_account("webuser")

      body = @recommended_path |> xrpc_get(token(user)) |> json_body()

      assert body["services"]["atproto_pds"]["endpoint"] == Pesque.base_url()
      assert body["verificationMethods"]["atproto"] == account_key_did(user)
      refute Map.has_key?(body, "rotationKeys")
    end

    test "it needs an access token" do
      conn = xrpc_get(@recommended_path)

      assert conn.status == 401
    end
  end

  describe "submitPlcOperation" do
    setup do
      put_identity(:plc)
      put_env(:plc_client, Pesque.Plc.TestClient)
      :ok
    end

    test "a valid operation is submitted and stored" do
      user = create_plc_account("alice")
      operation = operation(user)
      Process.put(:plc_resolve_result, {:ok, pds_document(user.did, Pesque.base_url())})

      conn = xrpc_post(@submit_path, %{"operation" => operation}, token(user))

      assert conn.status == 200
      assert {did, submitted} = Process.get(:plc_last_submit)
      assert did == user.did
      assert submitted == operation
      assert JSON.decode!(stored_operation(user)) == operation
    end

    test "an operation pointing at another PDS is refused and changes nothing" do
      user = create_plc_account("alice")
      before = stored_operation(user)

      operation =
        put_in(
          operation(user),
          ["services", "atproto_pds", "endpoint"],
          "https://elsewhere.example"
        )

      conn = xrpc_post(@submit_path, %{"operation" => operation}, token(user))

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
      refute Process.get(:plc_last_submit)
      assert stored_operation(user) == before
    end

    test "an operation carrying another key is refused and changes nothing" do
      user = create_plc_account("alice")
      before = stored_operation(user)
      {other_pub, _priv} = Secp256k1.generate_keypair()

      operation =
        put_in(operation(user), ["verificationMethods", "atproto"], Did.key_did(other_pub))

      conn = xrpc_post(@submit_path, %{"operation" => operation}, token(user))

      assert conn.status == 400
      refute Process.get(:plc_last_submit)
      assert stored_operation(user) == before
    end

    test "an operation for another handle is refused and changes nothing" do
      user = create_plc_account("alice")
      before = stored_operation(user)
      operation = put_in(operation(user), ["alsoKnownAs"], ["at://someone.else"])

      conn = xrpc_post(@submit_path, %{"operation" => operation}, token(user))

      assert conn.status == 400
      refute Process.get(:plc_last_submit)
      assert stored_operation(user) == before
    end

    test "a submit the directory refuses leaves the account untouched" do
      user = create_plc_account("alice")
      before = stored_operation(user)
      Process.put(:plc_submit_result, {:error, :plc_unreachable})

      conn = xrpc_post(@submit_path, %{"operation" => operation(user)}, token(user))

      assert conn.status == 500
      assert stored_operation(user) == before
    end
  end

  defp create_plc_account(name) do
    user = create_account(name)
    Process.delete(:plc_last_submit)
    user
  end

  defp operation(user) do
    %{
      "type" => "plc_operation",
      "rotationKeys" => [],
      "verificationMethods" => %{"atproto" => account_key_did(user)},
      "alsoKnownAs" => ["at://" <> user.handle],
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => Pesque.base_url()
        }
      },
      "prev" => nil
    }
  end

  defp pds_document(did, endpoint) do
    %{
      "id" => did,
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => endpoint
        }
      ]
    }
  end

  defp account_key_did(user) do
    {:ok, key} = Keys.ensure(user.did)
    Did.key_did(key.pub)
  end

  defp stored_operation(user), do: Accounts.get_user(user.did).plc_operation

  defp json_body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp put_identity(identity), do: put_env(:identity, identity)

  defp put_env(key, value) do
    previous = Application.get_env(:pesque, key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pesque, key, previous),
        else: Application.delete_env(:pesque, key)
    end)

    Application.put_env(:pesque, key, value)
    :ok
  end
end
