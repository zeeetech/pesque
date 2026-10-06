defmodule Pesque.HandleResolverTest do
  @moduledoc """
  Handle resolution against injected network primitives.

  Every case here runs with the DNS lookup and the HTTPS fetch supplied by the
  test, so nothing in this file touches the network and the answers are the
  same on every machine.
  """

  use ExUnit.Case, async: true

  alias Pesque.HandleResolver

  @did "did:web:pds.example.com:user:alice"
  @handle "alice.example.com"
  @well_known_suffix "/.well-known/atproto-did"

  defp document(did, aka), do: JSON.encode!(%{"id" => did, "alsoKnownAs" => aka})

  defp well_known_url?(url), do: String.ends_with?(url, @well_known_suffix)

  # A host that answers both halves: the well-known endpoint with `body`, and
  # every other URL (the DID document) with a document claiming `did` and
  # `aka`.
  defp host(did, body, aka) do
    fn url ->
      if well_known_url?(url),
        do: {:ok, 200, [], body},
        else: {:ok, 200, [], document(did, ["at://" <> aka])}
    end
  end

  # The common case: a TXT record that names the DID, and a host that answers
  # both the well-known endpoint and the DID document with it.
  defp resolving(did \\ @did, aka \\ @handle) do
    {fn _name -> {:ok, ["did=" <> did]} end, host(did, did, aka)}
  end

  # The same, with no TXT answer at all so resolution falls through to HTTPS.
  defp from_https(did \\ @did, aka \\ @handle) do
    {fn _name -> {:ok, []} end, host(did, did, aka)}
  end

  test "a TXT record that claims the handle resolves, and the document claims it back" do
    {dns, get} = resolving()

    assert HandleResolver.resolve(@handle, dns, get) == {:ok, @did}
  end

  test "the TXT record is read from _atproto under the handle" do
    {dns, get} = resolving()
    parent = self()

    dns = fn name ->
      send(parent, {:looked_up, name})
      dns.(name)
    end

    assert {:ok, @did} = HandleResolver.resolve(@handle, dns, get)
    assert_received {:looked_up, "_atproto.alice.example.com"}
  end

  test "a handle resolves through HTTPS when the DNS name does not exist" do
    {_dns, get} = from_https()

    assert HandleResolver.resolve(@handle, fn _name -> {:error, :nxdomain} end, get) ==
             {:ok, @did}
  end

  test "an empty TXT answer falls through to HTTPS" do
    {dns, get} = from_https()

    assert HandleResolver.resolve(@handle, dns, get) == {:ok, @did}
  end

  # Records that are not did= are somebody else's data on the same name, and
  # the spec says to ignore them rather than fail.
  test "a TXT answer with no did= record is ignored and HTTPS carries the handle" do
    records = ["v=spf1 -all", "some-other-verification-token"]
    {_dns, get} = from_https()

    assert HandleResolver.resolve(@handle, fn _name -> {:ok, records} end, get) == {:ok, @did}
  end

  # A zone mid-migration publishes both. Picking either would be a coin flip on
  # a name somebody may be attacking, so the spec says resolution fails.
  test "two different DIDs in the TXT records do not resolve to either" do
    {_unused, get} = from_https()

    assert HandleResolver.resolve(
             @handle,
             fn _name ->
               {:ok, ["did=" <> @did, "did=did:plc:someoneelse"]}
             end,
             get
           ) == {:error, :ambiguous_dns_record}
  end

  # The spec says a zone with two answers fails outright and can be retried
  # after a delay. Falling through to HTTPS would answer from whichever half of
  # a half-published name is serving, which is a guess dressed as a resolution.
  test "an ambiguous TXT answer does not fall through to HTTPS" do
    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 200, [], @did},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, :ambiguous_dns_record} =
             HandleResolver.resolve(
               @handle,
               fn _name ->
                 {:ok, ["did=" <> @did, "did=did:plc:someoneelse"]}
               end,
               get
             )
  end

  test "the same DID repeated in the TXT records is still one answer" do
    {_unused, get} = resolving()

    assert HandleResolver.resolve(
             @handle,
             fn _name -> {:ok, ["did=" <> @did, "did=" <> @did]} end,
             get
           ) ==
             {:ok, @did}
  end

  # A did= record carrying something that is not a DID is a broken publisher,
  # so the DNS method has not resolved the handle and HTTPS is asked. It is not
  # an error while the other method can still answer.
  test "a did= record whose value is not a DID is not an answer" do
    {_unused, get} = from_https()

    assert HandleResolver.resolve(@handle, fn _name -> {:ok, ["did=not-a-did"]} end, get) ==
             {:ok, @did}

    refused = fn _url -> {:error, :nxdomain} end

    assert {:error, {:https_failed, {:unreachable, :nxdomain}}} =
             HandleResolver.resolve(@handle, fn _name -> {:ok, ["did=not-a-did"]} end, refused)
  end

  # The record names a DID and the document does not name the handle back, so
  # the two are not linked. This is the impersonation the bidirectional check
  # exists to stop: without it alice.example.com could be published as an alias
  # of an attacker's DID.
  test "a DID whose document does not claim the handle is refused" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    get = host(@did, @did, "someone.else.com")

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "a document claiming a different DID than the one resolved is refused" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    get = host("did:plc:someoneelse", @did, @handle)

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "a handle whose document cannot be fetched is refused" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end

    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 200, [], @did},
        else: {:error, :nxdomain}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "the handle claim is compared on the normalized handle" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end
    get = host(@did, @did, "Alice.Example.com")

    assert HandleResolver.resolve(@handle, dns, get) == {:ok, @did}
  end

  test "a handle prefixed with @ and uppercase resolves to the same DID" do
    {dns, get} = resolving()

    assert HandleResolver.resolve("@" <> String.upcase(@handle), dns, get) == {:ok, @did}
  end

  test "a non-200 from the well-known endpoint does not resolve" do
    {dns, _get} = from_https()

    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 404, [], "not found"},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, {:https_failed, {:http_status, 404}}} =
             HandleResolver.resolve(@handle, dns, get)
  end

  test "a 500 from the well-known endpoint does not resolve" do
    {dns, _get} = from_https()

    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 500, [], ""},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, {:https_failed, {:http_status, 500}}} =
             HandleResolver.resolve(@handle, dns, get)
  end

  test "a redirect is followed to the DID" do
    get = fn
      "https://alice.example.com" <> @well_known_suffix ->
        {:ok, 301, [{~c"location", "https://www.example.com" <> @well_known_suffix}], ""}

      "https://www.example.com" <> @well_known_suffix ->
        {:ok, 200, [], @did}

      _did_document_url ->
        {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert HandleResolver.resolve(@handle, fn _name -> {:ok, []} end, get) == {:ok, @did}
  end

  test "a redirect loop is refused rather than followed forever" do
    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 302, [{~c"location", "https://alice.example.com" <> @well_known_suffix}], ""},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, {:https_failed, {:http_status, 302}}} =
             HandleResolver.resolve(@handle, fn _name -> {:ok, []} end, get)
  end

  # The spec requires https for every real resolution, so a redirect that drops
  # the scheme would move the answer off TLS.
  test "a redirect that downgrades to http is refused" do
    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 302, [{~c"location", "http://alice.example.com" <> @well_known_suffix}], ""},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, {:https_failed, {:bad_redirect, 302}}} =
             HandleResolver.resolve(@handle, fn _name -> {:ok, []} end, get)
  end

  test "a redirect with no location header is refused" do
    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 302, [], ""},
        else: {:ok, 200, [], document(@did, ["at://" <> @handle])}
    end

    assert {:error, {:https_failed, {:bad_redirect, 302}}} =
             HandleResolver.resolve(@handle, fn _name -> {:ok, []} end, get)
  end

  test "a malformed body from the well-known endpoint does not resolve" do
    {dns, _get} = from_https()

    get = fn url ->
      if well_known_url?(url), do: {:ok, 200, [], @did}, else: {:error, :timeout}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  # A primitive that raises is a bug or a library changing under us, and the
  # handle came from a stranger either way, so the answer is a reason.
  test "a primitive that raises answers an error rather than propagating it" do
    raising = fn _url -> raise "boom" end

    assert {:error, {:https_failed, {:unreachable, :resolver_failed}}} =
             HandleResolver.resolve(@handle, fn _name -> {:ok, []} end, raising)
  end

  test "a malformed DID document answers an error rather than resolving" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end

    get = fn url ->
      if well_known_url?(url), do: {:ok, 200, [], @did}, else: {:ok, 200, [], "{not json"}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "a document served as a JSON array is not a DID document" do
    dns = fn _name -> {:ok, ["did=" <> @did]} end

    get = fn url ->
      if well_known_url?(url),
        do: {:ok, 200, [], @did},
        else: {:ok, 200, [], "[{\"id\":\"" <> @did <> "\"}]"}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "a syntax-invalid handle never reaches the network" do
    parent = self()
    reached = fn _arg -> send(parent, :reached) end

    for handle <- [
          "alice",
          "alice..example.com",
          "alice.example.com.",
          "jo@hn.example.com",
          "-alice.example.com",
          "alice.-example.com",
          42,
          nil
        ] do
      assert {:error, reason} = HandleResolver.resolve(handle, reached, reached)
      assert reason in [:invalid_handle, :disallowed_handle]
      refute_received :reached
    end
  end

  # The spec names these as TLDs that must fail resolution outright.
  test "the disallowed top-level domains are refused" do
    reached = fn _arg -> flunk("the network was reached") end

    for handle <- [
          "alice.local",
          "alice.internal",
          "alice.onion",
          "alice.localhost",
          "alice.invalid",
          "alice.arpa",
          "alice.alt",
          "alice.example"
        ] do
      assert {:error, :disallowed_handle} = HandleResolver.resolve(handle, reached, reached)
    end
  end

  # did:web percent-encodes the port into the hostname, so the DID document has
  # to be fetched from a URL with the port restored or nothing is listening
  # there.
  test "a did:web with a percent-encoded port fetches its document from that port" do
    did = "did:web:localhost%3A4000"
    parent = self()

    dns = fn _name -> {:ok, ["did=" <> did]} end

    get = fn url ->
      send(parent, {:fetched, url})

      if well_known_url?(url),
        do: {:ok, 200, [], did},
        else: {:ok, 200, [], document(did, ["at://" <> @handle])}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:ok, did}
    assert_received {:fetched, "https://localhost:4000/.well-known/did.json"}
  end

  test "a did:plc document is fetched from the PLC directory" do
    did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    parent = self()

    dns = fn _name -> {:ok, ["did=" <> did]} end

    get = fn url ->
      send(parent, {:fetched, url})

      if well_known_url?(url),
        do: {:ok, 200, [], did},
        else: {:ok, 200, [], document(did, ["at://" <> @handle])}
    end

    assert HandleResolver.resolve(@handle, dns, get) == {:ok, did}
    assert_received {:fetched, "https://plc.directory/" <> ^did}
  end

  # The DID spec distinguishes "invalid DID syntax" from "unsupported DID
  # method", and only did:plc and did:web can have a document fetched here. One
  # that cannot must not have a URL guessed at it.
  test "an unsupported DID method is refused rather than fetched" do
    dns = fn _name -> {:ok, ["did=did:example:something"]} end
    get = fn _url -> flunk("an unsupported method was fetched") end

    assert HandleResolver.resolve(@handle, dns, get) == {:error, :not_bidirectional}
  end

  test "an IPv4 address is not a handle" do
    reached = fn _arg -> flunk("the network was reached") end

    assert {:error, :invalid_handle} = HandleResolver.resolve("192.0.2.1", reached, reached)
  end

  # The resolver answers a tuple whatever the primitives do, so no caller has to
  # wrap a call in a rescue to use it.
  test "the resolver returns a tuple for every input shape" do
    {dns, get} = resolving()

    for handle <- ["", "a.b", [], %{}, 42] do
      assert match?({:ok, _did}, HandleResolver.resolve(handle, dns, get)) or
               match?({:error, _reason}, HandleResolver.resolve(handle, dns, get))
    end
  end
end
