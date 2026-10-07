defmodule Pesque.HandleResolverTest do
  @moduledoc """
  Handle resolution against injected network primitives.

  The DNS lookup and the HTTPS fetch are passed in, and the DID document is read
  through a fake `Pesque.DidResolver`, so nothing here touches the network.
  """

  use ExUnit.Case, async: false

  alias Pesque.HandleResolver

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @handle "alice.example.com"
  @well_known_suffix "/.well-known/atproto-did"

  # A did:plc directory whose answer is configured per test. DidResolver reads
  # it from application env, so the fake sees what the test stored.
  defmodule Directory do
    def resolve(_did),
      do: Application.get_env(:pesque, :handle_resolver_test_document, {:error, :not_found})
  end

  setup do
    put_env(:did_resolver_directory, Directory)
    :ok
  end

  test "a TXT record naming the DID, with the document claiming the handle, verifies" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched despite a TXT answer") end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) == {:ok, @did}
    assert HandleResolver.verify(@handle, @did, dns_lookup: dns, http_get: http) == :ok
  end

  test "the TXT record is read from _atproto under the handle" do
    set_document(@did, ["at://" <> @handle])
    parent = self()

    dns = fn name ->
      send(parent, {:looked_up, name})
      {:ok, ["did=" <> @did]}
    end

    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert {:ok, @did} = HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http)
    assert_received {:looked_up, "_atproto.alice.example.com"}
  end

  test "a handle resolving to another DID is a mismatch" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert HandleResolver.verify(@handle, "did:plc:someoneelse", dns_lookup: dns, http_get: http) ==
             {:error, :handle_mismatch}
  end

  test "a missing TXT record falls through to the well-known endpoint" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:error, :nxdomain} end
    http = fn url -> if String.ends_with?(url, @well_known_suffix), do: {:ok, 200, [], @did} end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) == {:ok, @did}
  end

  # The impersonation the bidirectional check exists to stop: the handle
  # resolves to a DID whose document does not name it back.
  test "a document that does not claim the handle is refused even when the TXT matches" do
    set_document(@did, ["at://someone.else.com"])
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) ==
             {:error, :handle_not_claimed}
  end

  test "a document naming a different DID than the one resolved is refused" do
    set_document("did:plc:someoneelse", ["at://" <> @handle])
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) ==
             {:error, :handle_not_claimed}
  end

  # A zone mid-migration publishes both. Picking either would be a coin flip on
  # a name somebody may be attacking, so resolution fails and does not fall
  # through to whichever half is serving.
  test "two DIDs in the TXT answer do not resolve and do not fall through" do
    dns = fn _name -> {:ok, ["did=" <> @did, "did=did:plc:someoneelse"]} end
    http = fn _url -> flunk("the well-known endpoint was fetched for an ambiguous record") end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) ==
             {:error, :handle_unresolved}
  end

  test "the same DID repeated in the TXT records is still one answer" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:ok, ["did=" <> @did, "did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) == {:ok, @did}
  end

  test "a TXT answer with no did= record is ignored and the well-known carries the handle" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:ok, ["v=spf1 -all", "some-other-token"]} end
    http = fn url -> if String.ends_with?(url, @well_known_suffix), do: {:ok, 200, [], @did} end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) == {:ok, @did}
  end

  test "a non-2xx from the well-known endpoint does not resolve" do
    dns = fn _name -> {:ok, []} end
    http = fn _url -> {:ok, 404, [], "not found"} end

    assert HandleResolver.resolve(@handle, dns_lookup: dns, http_get: http) ==
             {:error, :handle_unresolved}
  end

  test "a primitive that raises answers an error rather than propagating it" do
    raising = fn _url -> raise "boom" end

    assert HandleResolver.resolve(@handle,
             dns_lookup: fn _name -> {:ok, []} end,
             http_get: raising
           ) ==
             {:error, :handle_unresolved}
  end

  test "a syntax-invalid handle never reaches the network" do
    reached = fn _arg -> flunk("the network was reached") end

    for handle <- [
          "alice",
          "alice..example.com",
          "alice.example.com.",
          "jo@hn.example.com",
          42,
          nil
        ] do
      assert HandleResolver.resolve(handle, dns_lookup: reached, http_get: reached) ==
               {:error, :invalid_handle}
    end
  end

  test "the disallowed top-level domains are refused" do
    reached = fn _arg -> flunk("the network was reached") end

    for handle <- ["alice.local", "alice.internal", "alice.onion", "alice.example"] do
      assert HandleResolver.resolve(handle, dns_lookup: reached, http_get: reached) ==
               {:error, :disallowed_handle}
    end
  end

  test "a handle prefixed with @ and uppercase resolves to the same DID" do
    set_document(@did, ["at://" <> @handle])
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    http = fn _url -> flunk("the well-known endpoint was fetched") end

    assert HandleResolver.resolve("@" <> String.upcase(@handle), dns_lookup: dns, http_get: http) ==
             {:ok, @did}
  end

  test "normalize settles the stored spelling and the syntax" do
    assert HandleResolver.normalize(" @Alice.Example.com ") == {:ok, "alice.example.com"}
    assert HandleResolver.normalize("alice.local") == {:error, :disallowed_handle}
    assert HandleResolver.normalize("alice") == {:error, :invalid_handle}
    assert HandleResolver.normalize(nil) == {:error, :invalid_handle}
  end

  defp set_document(did, aka) do
    put_env(:handle_resolver_test_document, {:ok, %{"id" => did, "alsoKnownAs" => aka}})
  end

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
