defmodule Pesque.OAuth.ClientTest do
  @moduledoc """
  Client metadata resolution, without touching the network.

  The client_id is a URL a stranger chose, so what is being tested here is the
  parsing and the rules applied to a document once fetched: a client cannot
  declare one thing and be addressed by another, and a document that does not
  meet the profile is refused rather than partially honoured.

  The remote fetch itself is not exercised here. It needs a real HTTPS server
  with a certificate this client trusts, and the part worth testing in it is
  already covered where it can be reached: the address check in
  Pesque.OAuth.Fetch is what stands between a client_id and the cloud metadata
  endpoint.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Client

  @localhost "http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%3A8080%2Fcallback"

  describe "the localhost development client" do
    test "is answered from a synthesized document, not fetched" do
      assert {:ok, metadata} = Client.resolve(@localhost)

      assert metadata["client_id"] == "http://localhost"
      assert metadata["response_types"] == ["code"]
      assert metadata["grant_types"] == ["authorization_code", "refresh_token"]
      assert metadata["token_endpoint_auth_method"] == "none"
      assert metadata["application_type"] == "native"
      assert metadata["dpop_bound_access_tokens"] == true
      assert metadata["scope"] == "atproto"
    end

    test "takes its redirect_uri from the query string" do
      assert {:ok, metadata} = Client.resolve(@localhost)

      assert metadata["redirect_uris"] == ["http://127.0.0.1:8080/callback"]
    end

    test "defaults its redirect_uris to the loopback pair when it declares none" do
      assert {:ok, metadata} = Client.resolve("http://localhost")

      assert metadata["redirect_uris"] == ["http://127.0.0.1/", "http://[::1]/"]
    end

    test "takes its scopes from the query string when it declares them" do
      id = "http://localhost?" <> URI.encode_query(%{"scope" => "atproto transition:generic"})

      assert {:ok, metadata} = Client.resolve(id)
      assert metadata["scope"] == "atproto transition:generic"
    end

    test "is a public client" do
      assert {:ok, metadata} = Client.resolve(@localhost)
      refute Client.confidential?(metadata)
    end
  end

  describe "a client_id that is not usable" do
    test "is refused rather than fetched" do
      for id <- [
            "http://localhost:3000",
            "http://localhost/path",
            "http://127.0.0.1",
            "http://example.com",
            "https://example.com:8443/metadata.json",
            "https://user:pass@example.com/metadata.json",
            "https://example.com/metadata.json#fragment",
            "ftp://example.com/metadata.json",
            "not a url at all",
            "",
            nil,
            42
          ] do
        assert {:error, :invalid_client_id} = Client.resolve(id), "accepted #{inspect(id)}"
      end
    end
  end

  describe "redirect_uri matching" do
    setup do
      {:ok, metadata} = Client.resolve(@localhost)
      %{metadata: metadata}
    end

    test "an exactly declared redirect_uri matches", ctx do
      assert Client.redirect_uri_allowed?(ctx.metadata, "http://127.0.0.1:8080/callback")
    end

    test "the port is not part of the match, because a native app picks one", ctx do
      assert Client.redirect_uri_allowed?(ctx.metadata, "http://127.0.0.1:9999/callback")
    end

    test "the path is part of the match", ctx do
      refute Client.redirect_uri_allowed?(ctx.metadata, "http://127.0.0.1:8080/other")
    end

    test "another host does not match", ctx do
      refute Client.redirect_uri_allowed?(ctx.metadata, "http://127.0.0.2:8080/callback")
      refute Client.redirect_uri_allowed?(ctx.metadata, "https://evil.example.com/callback")
    end

    test "a non-string is not a redirect_uri", ctx do
      refute Client.redirect_uri_allowed?(ctx.metadata, nil)
      refute Client.redirect_uri_allowed?(%{}, "http://127.0.0.1:8080/callback")
    end
  end

  describe "declared scopes" do
    setup do
      id = "http://localhost?" <> URI.encode_query(%{"scope" => "atproto transition:generic"})
      {:ok, metadata} = Client.resolve(id)
      %{metadata: metadata}
    end

    test "reads the declared list" do
      assert Client.declared_scopes(%{"scope" => "atproto transition:generic"}) == [
               "atproto",
               "transition:generic"
             ]

      assert Client.declared_scopes(%{}) == []
      assert Client.declared_scopes(nil) == []
    end

    test "a scope the client declared is allowed", ctx do
      assert Client.scopes_declared?(ctx.metadata, "atproto")
      assert Client.scopes_declared?(ctx.metadata, "atproto transition:generic")
    end

    test "a scope the client did not declare is not", ctx do
      refute Client.scopes_declared?(ctx.metadata, "transition:chat.bsky")
      refute Client.scopes_declared?(ctx.metadata, "atproto transition:chat.bsky")
    end
  end

  describe "client keys" do
    test "are read from an inline jwks" do
      assert {:ok, [%{"kid" => "one"}]} =
               Client.jwks(%{"jwks" => %{"keys" => [%{"kid" => "one"}]}})
    end

    test "are refused when the client published none" do
      assert {:error, :no_client_keys} = Client.jwks(%{})
      assert {:error, :no_client_keys} = Client.jwks(%{"jwks" => %{"keys" => []}})
      assert {:error, :no_client_keys} = Client.jwks(%{"jwks_uri" => "http://localhost"})
    end
  end
end
