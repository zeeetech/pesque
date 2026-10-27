defmodule Pesque.DidTest do
  use ExUnit.Case, async: true

  alias Pesque.Did

  @multibase "zQ3shYkUJ2lPvBNGaJmZJXGPFYqQCnEBWcVGY7DKZqFmVKZ"

  defp identity(overrides \\ []) do
    Enum.into(
      overrides,
      %{
        username: nil,
        hostname: "example.com",
        port: 443,
        handle_domain: "example.com",
        pub_multibase: @multibase
      }
    )
  end

  test "did_host percent-encodes the port on a loopback host" do
    assert Did.did_host("localhost", 4000) == "localhost%3A4000"
    assert Did.did_host("127.0.0.1", 3000) == "127.0.0.1%3A3000"
  end

  test "did_host percent-encodes the port on a private host" do
    assert Did.did_host("192.168.1.50", 4000) == "192.168.1.50%3A4000"
    assert Did.did_host("172.16.0.9", 4000) == "172.16.0.9%3A4000"
    assert Did.did_host("10.0.0.2", 4000) == "10.0.0.2%3A4000"
  end

  test "did_host drops the port on a public host whatever it listens on" do
    assert Did.did_host("example.com", 3000) == "example.com"
    assert Did.did_host("pds.example.com", 4000) == "pds.example.com"
    assert Did.did_host("example.com", nil) == "example.com"
  end

  test "did_host drops the port on loopback when nothing is behind 443" do
    assert Did.did_host("localhost", 443) == "localhost"
    assert Did.did_host("localhost", nil) == "localhost"
  end

  test "a private range boundary is not treated as private" do
    assert Did.did_host("172.15.0.1", 4000) == "172.15.0.1"
    assert Did.did_host("172.32.0.1", 4000) == "172.32.0.1"
    assert Did.did_host("11.0.0.1", 4000) == "11.0.0.1"
  end

  test "single derives the host-level did and the bare handle" do
    assert Did.did_for_username(:single, "example.com", nil) == "did:web:example.com"

    assert Did.did_for_username(:single, "example.com", "alice") ==
             "did:web:example.com"

    assert Did.handle_for_username(:single, "example.com", nil) == "example.com"
    assert Did.handle_for_username(:single, "example.com", "alice") == "example.com"
  end

  # Multi accounts are always did:plc, minted by the directory; this function
  # never derives a per-user did:web for them (the old path-based form is not a
  # valid ATProto DID). Only the host DID and the per-user handle come from here.
  test "multi derives the host did for the server and a per-user handle" do
    assert Did.did_for_username(:multi, "example.com", nil) == "did:web:example.com"
    assert Did.handle_for_username(:multi, "example.com", "alice") == "alice.example.com"

    assert_raise FunctionClauseError, fn ->
      apply(Did, :did_for_username, [:multi, "example.com", "alice"])
    end
  end

  test "a nil username is the server itself in either mode" do
    assert Did.did_for_username(:multi, "example.com", nil) == "did:web:example.com"
    assert Did.handle_for_username(:multi, "example.com", nil) == "example.com"
  end

  test "a username is normalized on the way into a handle" do
    assert Did.handle_for_username(:multi, "example.com", " Alice ") == "alice.example.com"
    assert Did.handle_for_username(:multi, "example.com", "@Alice") == "alice.example.com"
  end

  test "an unusable username raises rather than minting an unresolvable handle" do
    assert_raise ArgumentError, fn -> Did.handle_for_username(:multi, "example.com", "no!") end
    assert_raise ArgumentError, fn -> Did.handle_for_username(:multi, "example.com", "-x") end
  end

  test "normalize_username accepts handle labels and rejects the rest" do
    assert Did.normalize_username("Alice") == {:ok, "alice"}
    assert Did.normalize_username(" @bob ") == {:ok, "bob"}

    assert Did.normalize_username("a" <> String.duplicate("b", 62)) ==
             {:ok, "a" <> String.duplicate("b", 62)}

    assert Did.normalize_username("") == {:error, :empty}
    assert Did.normalize_username("-bob") == {:error, :invalid}
    assert Did.normalize_username("bob.smith") == {:error, :invalid}
    assert Did.normalize_username(42) == {:error, :not_a_string}
  end

  test "path_for_did follows the did:web resolution rules" do
    assert Did.path_for_did("did:web:example.com") == "/.well-known/did.json"

    assert Did.path_for_did("did:web:example.com:user:alice") == "/user/alice/did.json"

    assert Did.path_for_did("did:web:localhost%3A4000:user:alice") == "/user/alice/did.json"
    assert Did.path_for_did("did:plc:abc123") == {:error, :invalid_did}
  end

  test "the single document is the host-level identity" do
    assert Did.did_document(:single, identity()) == %{
             "@context" => [
               "https://www.w3.org/ns/did/v1",
               "https://w3id.org/security/multikey/v1"
             ],
             "id" => "did:web:example.com",
             "alsoKnownAs" => ["at://example.com"],
             "verificationMethod" => [
               %{
                 "id" => "did:web:example.com#atproto",
                 "type" => "Multikey",
                 "controller" => "did:web:example.com",
                 "publicKeyMultibase" => @multibase
               }
             ],
             "service" => [
               %{
                 "id" => "#atproto_pds",
                 "type" => "AtprotoPersonalDataServer",
                 "serviceEndpoint" => "https://example.com"
               }
             ]
           }
  end

  # did_document/2 builds the host document. A multi account's document is a
  # did:plc one (Did.plc_document/1), so the multi call here is the server's own
  # host document, whose DID is the host form regardless of any username.
  test "the multi host document carries the host did and a server-wide endpoint" do
    doc = Did.did_document(:multi, identity())

    assert doc["id"] == "did:web:example.com"
    assert doc["alsoKnownAs"] == ["at://example.com"]

    assert doc["verificationMethod"] == [
             %{
               "id" => "did:web:example.com#atproto",
               "type" => "Multikey",
               "controller" => "did:web:example.com",
               "publicKeyMultibase" => @multibase
             }
           ]

    assert doc["service"] == [
             %{
               "id" => "#atproto_pds",
               "type" => "AtprotoPersonalDataServer",
               "serviceEndpoint" => "https://example.com"
             }
           ]
  end

  test "the endpoint is scheme, hostname, and nothing per user" do
    [service] = Did.did_document(:multi, identity())["service"]
    assert service["serviceEndpoint"] == "https://example.com"
  end

  test "the document did matches the did the same mode derives" do
    for mode <- [:single, :multi] do
      doc = Did.did_document(mode, identity())

      assert doc["id"] ==
               Did.did_for_username(mode, Did.did_host("example.com", 443), nil)
    end
  end

  test "the document did carries the port only on a local host" do
    doc =
      Did.did_document(
        :multi,
        identity(hostname: "localhost", port: 4000)
      )

    assert doc["id"] == "did:web:localhost%3A4000"
    assert Did.path_for_did(doc["id"]) == "/.well-known/did.json"
  end

  # The two-identifier form had to guess whether a handle domain was the did
  # host, and guessed wrong for a percent-encoded port and for any host that
  # differs from the handle domain. Callers resolve then compare strings.
  test "there is no two-identifier comparison to regress into" do
    refute function_exported?(Did, :same_account?, 2)
    refute function_exported?(Did, :mirrors?, 2)
  end
end
