defmodule Pesque.ServerIdentityTest do
  @moduledoc """
  The server's own identity, and how a single account's DID method is chosen.

  The server's own DID is always `did:web:<hostname>`: derived, never minted,
  never persisted to a file, and always served. `Identity.load!/0` loads the
  host signing key and touches neither the network nor the database.

  A single account's DID method is chosen at creation time (`--identity
  web|plc`), not by a server-wide config knob. A web account shares the host
  DID; a plc account is minted through the directory at creation.
  """

  use Pesque.DataCase, async: false

  import Phoenix.ConnTest

  alias Pesque.Accounts
  alias Pesque.Identity

  @password "hunter2hunter2"

  setup do
    restore_env()
    :ok
  end

  test "the host did is always did:web of the hostname, in both modes" do
    expected = Identity.did()
    assert String.starts_with?(expected, "did:web:")

    for mode <- [:single, :multi] do
      Application.put_env(:pesque, :mode, mode)
      assert Identity.did() == expected
    end
  end

  test "load!/0 loads the host key and touches no network and no file" do
    assert :ok = Identity.load!()
    assert is_binary(Identity.public_key_multibase())
    refute File.exists?(Path.join(Pesque.data_dir(), "server.identity.json"))
  end

  test "a single web account shares the host did and mints nothing" do
    Application.put_env(:pesque, :mode, :single)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_last_submit, nil)

    assert {:ok, user} =
             Accounts.create_account(Identity.handle(), "server@localhost", @password,
               identity: :web
             )

    assert user.did == Identity.did()
    assert String.starts_with?(user.did, "did:web:")
    assert is_nil(user.plc_operation)
    assert Pesque.FakeStore.get(:plc_last_submit) == nil
  end

  test "a single plc account is minted at creation, not at boot" do
    Application.put_env(:pesque, :mode, :single)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_submit_result, :ok)
    Pesque.FakeStore.put(:plc_last_submit, nil)

    # Boot itself mints nothing: the host identity is did:web.
    assert :ok = Identity.load!()
    assert Pesque.FakeStore.get(:plc_last_submit) == nil

    assert {:ok, user} =
             Accounts.create_account(Identity.handle(), "server@localhost", @password,
               identity: :plc
             )

    assert String.starts_with?(user.did, "did:plc:")
    assert is_binary(user.plc_operation)
    # The DID was minted once, at creation, through the directory.
    did = user.did
    assert {^did, _op} = Pesque.FakeStore.get(:plc_last_submit)
    # No server identity file is written; the account row carries the operation.
    refute File.exists?(Path.join(Pesque.data_dir(), "server.identity.json"))

    conn = %Plug.Conn{build_conn() | host: Pesque.hostname()}
    conn = dispatch(conn, PesqueWeb.Endpoint, :get, "/.well-known/atproto-did", nil)
    assert conn.status == 200
    assert conn.resp_body == user.did
  end

  test "a multi account defaults to did:plc" do
    Application.put_env(:pesque, :mode, :multi)
    Application.put_env(:pesque, :handle_domain, "example.com")
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_submit_result, :ok)

    assert {:ok, user} =
             Accounts.create_account("alice.example.com", "a@example.com", @password)

    assert String.starts_with?(user.did, "did:plc:")
  end

  test "did:web under multi is refused" do
    Application.put_env(:pesque, :mode, :multi)
    Application.put_env(:pesque, :handle_domain, "example.com")

    assert {:error, :web_not_supported_under_multi} =
             Accounts.create_account("alice.example.com", "a@example.com", @password,
               identity: :web
             )
  end

  # The host document is served in every mode and for every account method:
  # the server's own did:web document is the host identity, independent of any
  # account's method.
  test "the well-known did document is served in both modes" do
    for mode <- [:single, :multi] do
      Application.put_env(:pesque, :mode, mode)

      conn = dispatch(build_conn(), PesqueWeb.Endpoint, :get, "/.well-known/did.json", nil)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["id"] == Identity.did()
    end
  end

  test "the doctor checks the local host document, never a plc one" do
    Application.put_env(:pesque, :mode, :single)

    http = fn url ->
      if String.ends_with?(url, "/.well-known/did.json") do
        document = %{
          "verificationMethod" => [
            %{
              "id" => Identity.did() <> "#atproto",
              "publicKeyMultibase" => Identity.public_key_multibase()
            }
          ]
        }

        {:ok, 200, JSON.encode!(document)}
      else
        {:ok, 404, ""}
      end
    end

    results =
      Pesque.Doctor.checks(
        http: http,
        resolver: fn _host -> {:ok, ["203.0.113.7"]} end,
        resolves: fn _handle, _did -> true end
      )

    assert {:ok, "did document", _detail} =
             Enum.find(results, &(elem(&1, 1) == "did document"))

    refute Enum.any?(results, &(elem(&1, 1) == "plc document"))
  end

  defp restore_env do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each([:mode, :handle_domain, :plc_client], &Application.delete_env(:pesque, &1))
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)
  end
end
