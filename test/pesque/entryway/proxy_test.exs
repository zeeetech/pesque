defmodule Pesque.Entryway.ProxyTest do
  @moduledoc """
  The pure half of the entryway. No database, no config, no process.
  """

  use ExUnit.Case, async: true

  alias Pesque.Entryway.Outbound
  alias Pesque.Entryway.Proxy

  describe "parse_header/1" do
    test "a nil header is missing" do
      assert Proxy.parse_header(nil) == {:error, :missing_proxy}
    end

    test "a did#serviceId reference parses" do
      assert Proxy.parse_header("did:web:api.bsky.app#bsky_appview") ==
               {:ok, %{did: "did:web:api.bsky.app", service_id: "bsky_appview"}}
    end

    test "surrounding whitespace is trimmed" do
      assert Proxy.parse_header("  did:plc:abc#bsky_chat  ") ==
               {:ok, %{did: "did:plc:abc", service_id: "bsky_chat"}}
    end

    test "anything that is not a did#serviceId reference is invalid" do
      for value <- ["", "did:plc:abc", "did:plc:abc#", "#svc", "not-a-did#svc"] do
        assert Proxy.parse_header(value) == {:error, :invalid_proxy}
      end
    end

    test "a non-binary header is invalid" do
      assert Proxy.parse_header(42) == {:error, :invalid_proxy}
    end
  end

  describe "valid_nsid?/1" do
    test "accepts an XRPC method name" do
      assert Proxy.valid_nsid?("app.bsky.actor.getPreferences")
    end

    test "rejects anything that is not one" do
      for value <- ["", "app.bsky", "../../etc", "app.bsky.feed.getTimeline/extra"] do
        refute Proxy.valid_nsid?(value)
      end

      refute Proxy.valid_nsid?(nil)
      refute Proxy.valid_nsid?(42)
    end
  end

  describe "select_service/2" do
    test "matches a bare fragment id" do
      document = %{
        "service" => [
          %{
            "id" => "#bsky_appview",
            "type" => "AtprotoPersonalDataServer",
            "serviceEndpoint" => "https://api.bsky.app"
          }
        ]
      }

      assert {:ok, %URI{scheme: "https", host: "api.bsky.app"}} =
               Proxy.select_service(document, "bsky_appview")
    end

    test "matches a full-DID id" do
      document = %{
        "service" => [
          %{
            "id" => "did:web:api.bsky.app#bsky_appview",
            "type" => "AtprotoPersonalDataServer",
            "serviceEndpoint" => "https://api.bsky.app"
          }
        ]
      }

      assert {:ok, %URI{host: "api.bsky.app"}} = Proxy.select_service(document, "bsky_appview")
    end

    test "a document with no service list is not found" do
      assert Proxy.select_service(%{"id" => "did:plc:abc"}, "bsky_appview") ==
               {:error, :service_not_found}
    end

    test "a named service without an endpoint is invalid" do
      document = %{"service" => [%{"id" => "#bsky_appview"}]}

      assert Proxy.select_service(document, "bsky_appview") ==
               {:error, :invalid_service_endpoint}
    end

    test "an http endpoint is refused" do
      document = %{
        "service" => [%{"id" => "#bsky_appview", "serviceEndpoint" => "http://api.bsky.app"}]
      }

      assert Proxy.select_service(document, "bsky_appview") ==
               {:error, :invalid_service_endpoint}
    end

    test "a non-map document is not found" do
      assert Proxy.select_service(nil, "bsky_appview") == {:error, :service_not_found}
    end
  end

  describe "build_outbound/1" do
    test "merges the endpoint with the method path and the query" do
      outbound = outbound(%{query: "limit=10"})

      assert %Outbound{method: :get, body: nil} = outbound

      assert URI.to_string(outbound.uri) ==
               "https://api.bsky.app/xrpc/app.bsky.feed.getTimeline?limit=10"
    end

    test "replaces the endpoint's own path" do
      outbound = outbound(%{endpoint: URI.parse("https://api.bsky.app/base")})

      assert URI.to_string(outbound.uri) == "https://api.bsky.app/xrpc/app.bsky.feed.getTimeline"
    end

    test "drops the hop-by-hop and authority headers, keeps the rest" do
      headers = [
        {"host", "evil.example"},
        {"authorization", "Bearer the-client-token"},
        {"atproto-proxy", "did:plc:abc#svc"},
        {"atproto-accept-labelers", "did:plc:labeller"},
        {"content-type", "application/json"}
      ]

      outbound = outbound(%{headers: headers})

      assert header(outbound, "authorization") == "Bearer the-service-token"
      assert header(outbound, "accept") == "application/json"
      assert header(outbound, "atproto-accept-labelers") == "did:plc:labeller"
      assert header(outbound, "content-type") == "application/json"
      refute has_header?(outbound, "host")
      refute has_header?(outbound, "atproto-proxy")
    end

    test "a POST carries its body" do
      outbound = outbound(%{method: :post, body: ~s({"x":1})})

      assert outbound.method == :post
      assert outbound.body == ~s({"x":1})
    end
  end

  defp outbound(overrides) do
    base = %{
      method: :get,
      nsid: "app.bsky.feed.getTimeline",
      endpoint: URI.parse("https://api.bsky.app"),
      query: "",
      body: nil,
      token: "the-service-token",
      headers: []
    }

    Proxy.build_outbound(Map.merge(base, overrides))
  end

  defp header(outbound, name) do
    case List.keyfind(outbound.headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp has_header?(outbound, name), do: List.keymember?(outbound.headers, name, 0)
end
