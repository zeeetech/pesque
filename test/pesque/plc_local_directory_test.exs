defmodule Pesque.Plc.LocalDirectoryTest do
  @moduledoc """
  The development PLC directory.

  An operation written under the data directory comes back as the document the
  real directory would have built, and a DID nothing was written for is asked of
  the directory that is really there. The remote is stubbed, so nothing here
  reaches plc.directory.
  """

  use ExUnit.Case, async: false

  alias Pesque.Plc.LocalDirectory

  setup do
    Pesque.FakeStore.clear()
    did = "did:plc:" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    previous = Application.get_env(:pesque, :plc_local_remote)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf(Path.join(Pesque.data_dir(), "plc"))
      restore(previous)
    end)

    %{did: did}
  end

  test "an operation written comes back as a document naming this server", %{did: did} do
    op = %{
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => "https://pds.example.com"
        }
      }
    }

    assert :ok = LocalDirectory.submit(did, op)

    assert {:ok, document} = LocalDirectory.resolve(did)
    assert document["id"] == did

    assert [%{"id" => id, "type" => type, "serviceEndpoint" => endpoint}] = document["service"]
    assert id == did <> "#atproto_pds"
    assert type == "AtprotoPersonalDataServer"
    assert endpoint == "https://pds.example.com"
  end

  test "a DID nothing was written for goes to the real directory", %{did: did} do
    Application.put_env(:pesque, :plc_local_remote, Pesque.Plc.TestClient)
    Pesque.FakeStore.put(:plc_resolve_result, {:ok, %{"id" => did}})

    assert {:ok, %{"id" => ^did}} = LocalDirectory.resolve(did)
  end

  defp restore(nil), do: Application.delete_env(:pesque, :plc_local_remote)
  defp restore(previous), do: Application.put_env(:pesque, :plc_local_remote, previous)
end
