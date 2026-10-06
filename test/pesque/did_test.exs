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

  defp server(overrides) do
    Enum.into(
      overrides,
      %{
        mode: :conformant_single,
        hostname: "example.com",
        port: 443,
        handle_domain: "example.com"
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

  test "conformant_single derives the host-level did and the bare handle" do
    assert Did.did_for_username(:conformant_single, "example.com", nil) == "did:web:example.com"

    assert Did.did_for_username(:conformant_single, "example.com", "alice") ==
             "did:web:example.com"

    assert Did.handle_for_username(:conformant_single, "example.com", nil) == "example.com"
    assert Did.handle_for_username(:conformant_single, "example.com", "alice") == "example.com"
  end

  test "path_multi derives a path did and a per-user handle" do
    assert Did.did_for_username(:path_multi, "example.com", "alice") ==
             "did:web:example.com:user:alice"

    assert Did.handle_for_username(:path_multi, "example.com", "alice") == "alice.example.com"
  end

  test "a nil username is the server itself in either mode" do
    assert Did.did_for_username(:path_multi, "example.com", nil) == "did:web:example.com"
    assert Did.handle_for_username(:path_multi, "example.com", nil) == "example.com"
  end

  test "a username is normalized on the way into a did or a handle" do
    assert Did.did_for_username(:path_multi, "example.com", "@Alice") ==
             "did:web:example.com:user:alice"

    assert Did.handle_for_username(:path_multi, "example.com", " Alice ") == "alice.example.com"
  end

  test "an unusable username raises rather than minting an unresolvable did" do
    assert_raise ArgumentError, fn -> Did.did_for_username(:path_multi, "example.com", "no!") end
    assert_raise ArgumentError, fn -> Did.did_for_username(:path_multi, "example.com", "-x") end
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

  test "username_from_did reads the path did and rejects anything else" do
    assert Did.username_from_did(:path_multi, "did:web:example.com:user:alice") == {:ok, "alice"}
    assert Did.username_from_did(:path_multi, "did:web:example.com") == {:error, :invalid_did}

    assert Did.username_from_did(:path_multi, "did:web:example.com:user") ==
             {:error, :invalid_did}

    assert Did.username_from_did(:conformant_single, "did:web:example.com:user:alice") ==
             {:error, :invalid_did}
  end

  test "path_for_did follows the did:web resolution rules" do
    assert Did.path_for_did("did:web:example.com") == "/.well-known/did.json"

    assert Did.path_for_did("did:web:example.com:user:alice") == "/user/alice/did.json"

    assert Did.path_for_did("did:web:localhost%3A4000:user:alice") == "/user/alice/did.json"
    assert Did.path_for_did("did:plc:abc123") == {:error, :invalid_did}
  end

  test "the conformant_single document is the host-level identity" do
    assert Did.did_document(:conformant_single, identity()) == %{
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

  test "the path_multi document carries the per-user did and a server-wide endpoint" do
    doc = Did.did_document(:path_multi, identity(username: "alice"))

    assert doc["id"] == "did:web:example.com:user:alice"
    assert doc["alsoKnownAs"] == ["at://alice.example.com"]

    assert doc["verificationMethod"] == [
             %{
               "id" => "did:web:example.com:user:alice#atproto",
               "type" => "Multikey",
               "controller" => "did:web:example.com:user:alice",
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
    for username <- [nil, "alice"] do
      [service] = Did.did_document(:path_multi, identity(username: username))["service"]
      endpoint = service["serviceEndpoint"]

      assert endpoint == "https://example.com"
      refute String.contains?(endpoint, username || "alice")
    end
  end

  test "the document did matches the did the same mode derives" do
    for mode <- [:conformant_single, :path_multi] do
      doc = Did.did_document(mode, identity(username: "alice"))

      assert doc["id"] ==
               Did.did_for_username(mode, Did.did_host("example.com", 443), "alice")
    end
  end

  test "the document did carries the port only on a local host" do
    doc =
      Did.did_document(
        :path_multi,
        identity(username: "alice", hostname: "localhost", port: 4000)
      )

    assert doc["id"] == "did:web:localhost%3A4000:user:alice"
    assert Did.path_for_did(doc["id"]) == "/user/alice/did.json"
  end

  test "a path_multi handle and its did resolve to the same did" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, "alice.example.com") ==
             {:ok, "did:web:example.com:user:alice"}

    assert Did.to_local_did(config, "did:web:example.com:user:alice") ==
             {:ok, "did:web:example.com:user:alice"}
  end

  test "resolution holds when the did host carries a percent-encoded port" do
    config =
      server(mode: :path_multi, hostname: "127.0.0.1", port: 4111, handle_domain: "127.0.0.1")

    did = "did:web:127.0.0.1%3A4111:user:alice"

    assert Did.to_local_did(config, did) == {:ok, did}
    assert Did.to_local_did(config, "alice.127.0.0.1") == {:ok, did}
  end

  test "a handle domain that differs from the did host still resolves" do
    config = server(mode: :path_multi, hostname: "pds.example.com", handle_domain: "example.com")

    assert Did.to_local_did(config, "alice.example.com") ==
             {:ok, "did:web:pds.example.com:user:alice"}

    assert Did.to_local_did(config, "did:web:pds.example.com:user:alice") ==
             {:ok, "did:web:pds.example.com:user:alice"}
  end

  test "an identifier that resolves differently by mode is not silently accepted" do
    single = server(mode: :conformant_single)

    assert Did.to_local_did(single, "did:web:example.com") == {:ok, "did:web:example.com"}

    assert Did.to_local_did(server(mode: :path_multi), "did:web:example.com") ==
             {:error, :not_local}
  end

  # Each mode names its accounts differently, so the two identifier shapes
  # are exclusive: the bare form means the single server account and only
  # resolves there, the labeled form means a per-user account and only
  # resolves there. Neither mode may start accepting the other's shape.
  test "bare and labeled identifiers are exclusive to one mode each" do
    single = server(mode: :conformant_single)
    multi = server(mode: :path_multi)

    assert Did.to_local_did(single, "example.com") == {:ok, "did:web:example.com"}
    assert Did.to_local_did(single, "did:web:example.com") == {:ok, "did:web:example.com"}
    assert Did.to_local_did(single, "alice.example.com") == {:error, :not_local}
    assert Did.to_local_did(single, "did:web:example.com:user:alice") == {:error, :not_local}

    assert Did.to_local_did(multi, "alice.example.com") ==
             {:ok, "did:web:example.com:user:alice"}

    assert Did.to_local_did(multi, "did:web:example.com:user:alice") ==
             {:ok, "did:web:example.com:user:alice"}

    assert Did.to_local_did(multi, "example.com") == {:error, :not_local}
    assert Did.to_local_did(multi, "did:web:example.com") == {:error, :not_local}
  end

  test "the bare handle domain is the server's own handle under conformant_single" do
    config = server(mode: :conformant_single)

    assert Did.to_local_did(config, "example.com") == {:ok, "did:web:example.com"}
    assert Did.to_local_did(config, "EXAMPLE.COM") == {:ok, "did:web:example.com"}

    split =
      server(mode: :conformant_single, hostname: "pds.example.com", handle_domain: "example.com")

    assert Did.to_local_did(split, "example.com") == {:ok, "did:web:pds.example.com"}
  end

  test "the bare handle domain names no account under path_multi" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, "example.com") == {:error, :not_local}

    lan = server(mode: :path_multi, hostname: "127.0.0.1", port: 4111, handle_domain: "127.0.0.1")
    assert Did.to_local_did(lan, "127.0.0.1") == {:error, :not_local}
  end

  test "a bare handle under a domain this server does not serve is not local" do
    config =
      server(mode: :conformant_single, hostname: "pds.example.com", handle_domain: "example.com")

    assert Did.to_local_did(config, "evil.com") == {:error, :not_local}
    assert Did.to_local_did(config, "pds.example.com") == {:error, :not_local}
  end

  test "a handle with an empty or leading-dot label names nothing" do
    for mode <- [:conformant_single, :path_multi] do
      config = server(mode: mode)

      assert Did.to_local_did(config, ".example.com") == {:error, :not_local}
      assert Did.to_local_did(config, ".") == {:error, :not_local}
      assert Did.to_local_did(config, ".alice.example.com") == {:error, :not_local}
      assert Did.to_local_did(config, "example.com.") == {:error, :not_local}
      assert Did.to_local_did(config, "") == {:error, :not_local}
    end
  end

  test "a handle that merely resembles the handle domain is not local" do
    config = server(mode: :conformant_single)

    assert Did.to_local_did(config, "evil-example.com") == {:error, :not_local}
    assert Did.to_local_did(config, "notexample.com") == {:error, :not_local}
    assert Did.to_local_did(config, "xexample.com") == {:error, :not_local}
  end

  test "a handle under a domain this server does not serve is not local" do
    config = server(mode: :path_multi, hostname: "pds.example.com", handle_domain: "example.com")

    assert Did.to_local_did(config, "alice.evil.com") == {:error, :not_local}
    assert Did.to_local_did(config, "alice.pds.example.com") == {:error, :not_local}
  end

  test "a well-formed did of another host is not local" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, "did:web:other.com:user:alice") == {:error, :not_local}
    assert Did.to_local_did(config, "did:plc:abc123") == {:error, :not_local}
  end

  test "a did whose path is not exactly user/username is not local" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, "did:web:example.com:user:alice:extra") ==
             {:error, :not_local}

    assert Did.to_local_did(config, "did:web:example.com:user") == {:error, :not_local}
    assert Did.to_local_did(config, "did:web:example.com:alice") == {:error, :not_local}
    assert Did.to_local_did(config, "did:web:example.com:user:no!") == {:error, :not_local}
  end

  test "a bare host did is local in conformant_single only" do
    assert Did.to_local_did(server(mode: :conformant_single), "did:web:example.com") ==
             {:ok, "did:web:example.com"}

    assert Did.to_local_did(server(mode: :path_multi), "did:web:example.com") ==
             {:error, :not_local}
  end

  test "resolution is case insensitive on the host and the handle" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, "Alice.Example.com") ==
             {:ok, "did:web:example.com:user:alice"}

    assert Did.to_local_did(config, "DID:WEB:EXAMPLE.COM:USER:ALICE") ==
             {:ok, "did:web:example.com:user:alice"}

    assert Did.to_local_did(config, " alice.example.com ") ==
             {:ok, "did:web:example.com:user:alice"}
  end

  test "a non-identifier is not local" do
    config = server(mode: :path_multi)

    assert Did.to_local_did(config, nil) == {:error, :invalid_identifier}
    assert Did.to_local_did(config, 42) == {:error, :invalid_identifier}
    assert Did.to_local_did(config, "") == {:error, :not_local}
    assert Did.to_local_did(config, "alice") == {:error, :not_local}
  end

  # The two-identifier form had to guess whether a handle domain was the did
  # host, and guessed wrong for a percent-encoded port and for any host that
  # differs from the handle domain. Callers resolve then compare strings.
  test "there is no two-identifier comparison to regress into" do
    refute function_exported?(Did, :same_account?, 2)
    refute function_exported?(Did, :mirrors?, 2)
  end
end
