defmodule Pesque.ImportedHandleTest do
  @moduledoc """
  Foreign-handle verification at the import and handle-change boundaries.

  A handle under this server's own domain is resolved here and takes the
  no-network path. Any other handle has to resolve to the DID bidirectionally
  before a row is written. The handle resolver's DNS/HTTP primitives and the DID
  resolver are injected, so nothing here reaches the network.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts

  @password "hunter2hunter2"

  # A did:plc directory whose answer is configured per test.
  defmodule Directory do
    def resolve(_did),
      do: Application.get_env(:pesque, :imported_handle_document, {:error, :not_found})
  end

  setup do
    put_env(:did_resolver_directory, Directory)
    :ok
  end

  describe "create_imported_account/5" do
    test "accepts a foreign handle that resolves to the DID and is claimed back" do
      did = did()
      handle = "alice.zeetech.io"

      put_env(:imported_handle_document, {:ok, document(did, ["at://" <> handle])})
      put_env(:handle_resolver_dns, fn _name -> {:ok, ["did=" <> did]} end)
      put_env(:handle_resolver_http, fn _url -> flunk("the well-known endpoint was fetched") end)

      assert {:ok, user} =
               Accounts.create_imported_account(
                 handle,
                 unique("mail") <> "@zeetech.io",
                 @password,
                 did
               )

      assert user.handle == handle
      assert user.did == did
      assert user.username == nil
      refute user.active
    end

    test "refuses a foreign handle that does not resolve and writes nothing" do
      did = did()

      put_env(:handle_resolver_dns, fn _name -> {:error, :nxdomain} end)
      put_env(:handle_resolver_http, fn _url -> {:ok, 404, [], "not found"} end)

      assert {:error, :handle_unresolved} =
               Accounts.create_imported_account(
                 "alice.zeetech.io",
                 unique("mail") <> "@zeetech.io",
                 @password,
                 did
               )

      refute Accounts.get_user(did)
    end

    test "refuses a document that does not claim the handle and writes nothing" do
      did = did()
      handle = "alice.zeetech.io"

      put_env(:imported_handle_document, {:ok, document(did, ["at://someone.else.io"])})
      put_env(:handle_resolver_dns, fn _name -> {:ok, ["did=" <> did]} end)
      put_env(:handle_resolver_http, fn _url -> flunk("the well-known endpoint was fetched") end)

      assert {:error, :handle_not_claimed} =
               Accounts.create_imported_account(
                 handle,
                 unique("mail") <> "@zeetech.io",
                 @password,
                 did
               )

      refute Accounts.get_user(did)
    end

    test "takes a local handle without any network call" do
      did = did()
      handle = unique("local") <> ".localhost"

      put_env(:handle_resolver_dns, fn _name -> flunk("DNS was reached for a local handle") end)
      put_env(:handle_resolver_http, fn _url -> flunk("HTTP was reached for a local handle") end)

      assert {:ok, user} =
               Accounts.create_imported_account(
                 handle,
                 unique("mail") <> "@localhost",
                 @password,
                 did
               )

      assert user.handle == handle
      assert user.username == String.split(handle, ".") |> hd()
    end

    test "refuses a foreign handle under conformant_single" do
      put_env(:mode, :conformant_single)

      put_env(:handle_resolver_dns, fn _name ->
        flunk("a foreign handle is not claimed in this mode")
      end)

      assert {:error, :disallowed_handle} =
               Accounts.create_imported_account(
                 "alice.zeetech.io",
                 unique("mail") <> "@zeetech.io",
                 @password,
                 did()
               )
    end
  end

  describe "update_handle/2" do
    setup do
      put_env(:identity, :plc)
      put_env(:plc_client, Pesque.Plc.TestClient)
      :ok
    end

    test "moves a did:plc account to a foreign handle that resolves to its DID" do
      user = create_account("alice")
      handle = "alice.zeetech.io"

      put_env(:imported_handle_document, {:ok, document(user.did, ["at://" <> handle])})
      put_env(:handle_resolver_dns, fn _name -> {:ok, ["did=" <> user.did]} end)
      put_env(:handle_resolver_http, fn _url -> flunk("the well-known endpoint was fetched") end)

      assert {:ok, updated} = Accounts.update_handle(user, handle)
      assert updated.handle == handle
      assert updated.did == user.did
      assert Accounts.get_user(user.did).handle == handle
    end

    test "refuses a foreign handle that does not resolve and keeps the row" do
      user = create_account("alice")
      original = user.handle

      put_env(:handle_resolver_dns, fn _name -> {:error, :nxdomain} end)
      put_env(:handle_resolver_http, fn _url -> {:ok, 404, [], "not found"} end)

      assert {:error, :handle_unresolved} = Accounts.update_handle(user, "alice.zeetech.io")
      assert Accounts.get_user(user.did).handle == original
    end

    test "refuses a handle that resolves to another DID before the directory is touched" do
      user = create_account("alice")
      Process.delete(:plc_last_submit)

      put_env(:handle_resolver_dns, fn _name -> {:ok, ["did=" <> did()]} end)
      put_env(:handle_resolver_http, fn _url -> flunk("the well-known endpoint was fetched") end)

      assert {:error, :handle_mismatch} = Accounts.update_handle(user, "alice.zeetech.io")
      assert Process.get(:plc_last_submit) == nil
      assert Accounts.get_user(user.did).handle == user.handle
    end

    test "takes a local handle without any network call" do
      user = create_account("alice")
      handle = unique("fresh") <> ".localhost"

      put_env(:handle_resolver_dns, fn _name -> flunk("DNS was reached for a local handle") end)
      put_env(:handle_resolver_http, fn _url -> flunk("HTTP was reached for a local handle") end)

      assert {:ok, updated} = Accounts.update_handle(user, handle)
      assert updated.handle == handle
    end
  end

  defp did, do: "did:plc:" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp document(did, aka), do: %{"id" => did, "alsoKnownAs" => aka}

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
