defmodule Pesque.ServerIdentityTest do
  @moduledoc """
  The server's own identity under `mode = conformant_single, identity = plc`.

  The single account is the server, so its DID is the server's own: a did:plc
  minted once through the PLC directory and persisted to a file, because the
  Repo is not running yet when `Identity.load!/0` runs.

  The application boots with the test config (conformant_single + web), so
  these tests drive `Identity.load!/0` in-process with the environment swapped
  to plc, and restore the environment, the persistent terms it writes, and the
  identity file on exit so later tests are unaffected.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Pesque.Accounts
  alias Pesque.Identity
  alias Pesque.Storage

  @password "hunter2hunter2"

  @persistent_keys [
    {Pesque.Identity, :pub_multibase},
    {Pesque.Identity, :server_did},
    {Pesque.Identity, :server_operation}
  ]

  setup do
    Pesque.DataCase.setup()
    remove_identity_file()
    restore_env()
    restore_persistent_terms()
    :ok
  end

  test "the first boot mints a did:plc and persists it" do
    configure_plc()

    assert :ok = Identity.load!()
    assert String.starts_with?(Identity.did(), "did:plc:")
    assert is_binary(Identity.server_operation())
    assert File.exists?(Storage.server_identity_path())
  end

  test "a later boot reuses the persisted identity and does not mint again" do
    configure_plc()

    :ok = Identity.load!()
    did = Identity.did()
    Process.delete(:plc_last_submit)

    :ok = Identity.load!()

    assert Identity.did() == did
    assert Process.get(:plc_last_submit) == nil
  end

  test "the single account is created with the server's did:plc and mints no second one" do
    configure_plc()
    :ok = Identity.load!()
    Process.delete(:plc_last_submit)

    assert {:ok, user} =
             Accounts.create_account(Identity.handle(), "server@localhost", @password)

    assert user.did == Identity.did()
    assert String.starts_with?(user.did, "did:plc:")
    assert user.plc_operation == Identity.server_operation()
    assert Process.get(:plc_last_submit) == nil
  end

  # A did:plc resolves through plc.directory, so this route must not publish a
  # did:web-shaped document for it.
  test "the well-known did document is a 404 under plc" do
    Application.put_env(:pesque, :identity, :plc)

    conn = dispatch(build_conn(), PesqueWeb.Endpoint, :get, "/.well-known/did.json", nil)

    assert conn.status == 404
    assert conn.resp_body == ""
  end

  # Under plc the doctor must follow the DID to the directory, not fetch the
  # local route that now 404s.
  test "the doctor checks the plc directory document under plc" do
    configure_plc()
    :ok = Identity.load!()

    http = fn url ->
      if String.ends_with?(url, Identity.did()) do
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

    assert {:ok, "plc document", _detail} =
             Enum.find(results, &(elem(&1, 1) == "plc document"))
  end

  defp configure_plc do
    Application.put_env(:pesque, :mode, :conformant_single)
    Application.put_env(:pesque, :identity, :plc)
    Application.put_env(:pesque, :plc_client, Pesque.Plc.TestClient)
    Process.put(:plc_submit_result, :ok)
  end

  defp remove_identity_file do
    File.rm(Storage.server_identity_path())
    on_exit(fn -> File.rm(Storage.server_identity_path()) end)
  end

  defp restore_env do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each([:mode, :identity, :plc_client], &Application.delete_env(:pesque, &1))
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)
  end

  defp restore_persistent_terms do
    previous = Map.new(@persistent_keys, fn key -> {key, :persistent_term.get(key, :unset)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :unset} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)
  end
end
