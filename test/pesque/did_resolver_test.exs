defmodule Pesque.DidResolverTest do
  use ExUnit.Case, async: false

  alias Pesque.Did
  alias Pesque.DidResolver

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  @document %{
    "id" => @did,
    "verificationMethod" => [
      %{
        "id" => @did <> "#atproto",
        "type" => "Multikey",
        "controller" => @did,
        "publicKeyMultibase" => "zQ3shunBKsXixLxKtC5qeSG9E4J5RkGN57im31pcTzbNQnm5w"
      }
    ]
  }

  # The injected primitives never reach the network. They answer whatever the
  # test stored and tell the test process they were called, so ordering is
  # observable.
  defmodule Directory do
    def resolve(did) do
      notify({:directory, did})
      :persistent_term.get(:did_resolver_test_result, {:error, :not_found})
    end

    defp notify(message) do
      case :persistent_term.get(:did_resolver_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  defmodule Fetcher do
    def json(uri, _max_bytes) do
      case :persistent_term.get(:did_resolver_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, {:fetch, uri})
      end

      :persistent_term.get(:did_resolver_test_result, {:error, :not_found})
    end
  end

  defmodule RaisingDirectory do
    def resolve(_did), do: raise("the directory is down")
  end

  setup do
    :persistent_term.put(:did_resolver_test_pid, self())

    on_exit(fn ->
      :persistent_term.erase(:did_resolver_test_pid)
      :persistent_term.erase(:did_resolver_test_result)
      Application.delete_env(:pesque, :did_resolver_directory)
      Application.delete_env(:pesque, :did_resolver_fetch)
    end)

    :ok
  end

  test "resolves a did:plc through the injected directory" do
    directory(Directory)
    respond({:ok, @document})

    assert DidResolver.resolve(@did) == {:ok, @document}
    assert_received {:directory, @did}
  end

  test "resolves a did:web by fetching the document" do
    fetcher(Fetcher)
    respond({:ok, %{"id" => "did:web:example.com"}})

    assert {:ok, _document} = DidResolver.resolve("did:web:example.com")

    assert_received {:fetch, uri}
    assert uri.scheme == "https"
    assert uri.host == "example.com"
    assert uri.path == "/.well-known/did.json"
  end

  test "a did:web with a percent-encoded port fetches that port" do
    fetcher(Fetcher)
    respond({:ok, %{"id" => "did:web:localhost%3A4000"}})

    assert {:ok, _document} = DidResolver.resolve("did:web:localhost%3A4000")

    assert_received {:fetch, uri}
    assert uri.host == "localhost"
    assert uri.port == 4000
  end

  test "web_uri builds the well-known URL for a bare host" do
    assert {:ok, uri} = Did.web_uri("did:web:example.com")
    assert uri.scheme == "https"
    assert uri.host == "example.com"
    assert uri.path == "/.well-known/did.json"
  end

  test "web_uri decodes the port and keeps the path" do
    assert {:ok, uri} = Did.web_uri("did:web:localhost%3A4000:user:alice")
    assert uri.host == "localhost"
    assert uri.port == 4000
    assert uri.path == "/user/alice/did.json"
  end

  test "web_uri refuses anything that is not a did:web" do
    assert Did.web_uri("did:plc:abc123") == {:error, :invalid_did}
    assert Did.web_uri("did:web:") == {:error, :invalid_did}
    assert Did.web_uri("did:web") == {:error, :invalid_did}
    assert Did.web_uri(nil) == {:error, :invalid_did}
  end

  test "an unsupported DID method is an error, not a raise" do
    assert DidResolver.resolve("did:key:zQ3shZc2QzApp2oymGvQbzP8eKheVshBHbU4ZYjeXqwSKEn6N") ==
             {:error, :unsupported_did_method}
  end

  test "invalid DID syntax is an error, not a raise" do
    for did <- ["", "did:web:", "DID:WEB:example.com", "not-a-did", "did:web:example.com/"] do
      assert DidResolver.resolve(did) == {:error, :invalid_did}
    end

    assert DidResolver.resolve(nil) == {:error, :invalid_did}
    assert DidResolver.resolve(42) == {:error, :invalid_did}
  end

  test "a directory failure is passed through" do
    directory(Directory)
    respond({:error, :not_found})

    assert DidResolver.resolve(@did) == {:error, :not_found}
  end

  test "a document naming a different DID is refused" do
    directory(Directory)
    respond({:ok, %{"id" => "did:plc:someoneelse"}})

    assert DidResolver.resolve(@did) == {:error, :did_mismatch}
  end

  test "an answer that is not a DID document is refused" do
    directory(Directory)
    respond({:ok, "not a document"})

    assert DidResolver.resolve(@did) == {:error, :invalid_did_document}
  end

  test "a primitive that raises is an error, not a raise" do
    directory(RaisingDirectory)

    assert DidResolver.resolve(@did) == {:error, :did_resolution_failed}
  end

  defp directory(module), do: Application.put_env(:pesque, :did_resolver_directory, module)
  defp fetcher(module), do: Application.put_env(:pesque, :did_resolver_fetch, module)
  defp respond(result), do: :persistent_term.put(:did_resolver_test_result, result)
end
