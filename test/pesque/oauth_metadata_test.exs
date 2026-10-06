defmodule PesqueWeb.OAuth.MetadataTest do
  @moduledoc """
  The three documents a client reads before it does anything else.

  The assertions are the ones the atproto profile names as requirements rather
  than a shape check: a client that reads these and finds PAR not required, or
  plain PKCE offered, or ES256 absent from the DPoP algorithms, refuses to start
  at all.
  """

  use PesqueWeb.ConnCase, async: false

  import Bitwise

  @as_metadata "/.well-known/oauth-authorization-server"
  @rs_metadata "/.well-known/oauth-protected-resource"

  test "the authorization server metadata declares what the profile requires" do
    meta = json_response(fetch(@as_metadata), 200)

    assert meta["issuer"] == Pesque.base_url()
    assert meta["authorization_endpoint"] == Pesque.base_url() <> "/oauth/authorize"
    assert meta["token_endpoint"] == Pesque.base_url() <> "/oauth/token"
    assert meta["pushed_authorization_request_endpoint"] == Pesque.base_url() <> "/oauth/par"

    assert "code" in meta["response_types_supported"]
    assert "authorization_code" in meta["grant_types_supported"]
    assert "refresh_token" in meta["grant_types_supported"]

    # PKCE is mandatory and plain is not allowed.
    assert meta["code_challenge_methods_supported"] == ["S256"]

    # Both client types have to be offered: a browser app has no key, a web
    # service has one.
    assert "none" in meta["token_endpoint_auth_methods_supported"]
    assert "private_key_jwt" in meta["token_endpoint_auth_methods_supported"]
    refute "none" in meta["token_endpoint_auth_signing_alg_values_supported"]
    assert "ES256" in meta["token_endpoint_auth_signing_alg_values_supported"]

    assert "atproto" in meta["scopes_supported"]
    assert "transition:generic" in meta["scopes_supported"]

    assert "ES256" in meta["dpop_signing_alg_values_supported"]
    assert meta["require_pushed_authorization_requests"] == true
    assert meta["require_request_uri_registration"] == true
    assert meta["authorization_response_iss_parameter_supported"] == true
    assert meta["client_id_metadata_document_supported"] == true
  end

  test "the resource server metadata points at this server as the AS" do
    meta = json_response(fetch(@rs_metadata), 200)

    assert meta["resource"] == Pesque.base_url()
    assert meta["authorization_servers"] == [Pesque.base_url()]
    assert meta["bearer_methods_supported"] == ["DPoP"]
  end

  test "the JWKS carries the OAuth key and it is a P-256 key" do
    meta = json_response(fetch(@as_metadata), 200)
    jwks = json_response(fetch(meta["jwks_uri"]), 200)

    assert [jwk] = jwks["keys"]
    assert jwk["kty"] == "EC"
    assert jwk["crv"] == "P-256"
    assert jwk["alg"] == "ES256"
    assert jwk["use"] == "sig"
    assert byte_size(Base.url_decode64!(jwk["x"], padding: false)) == 32
    assert byte_size(Base.url_decode64!(jwk["y"], padding: false)) == 32
  end

  # The repository key is secp256k1, published in the DID document as multibase
  # starting z. The OAuth key is a separate P-256 file. Neither is derived from
  # the other, which is what stops a token verification path from ever touching
  # a commit signing key.
  test "the OAuth key is a separate P-256 file, not the repository key" do
    path = Pesque.OAuth.Keys.path()

    assert Path.basename(path) == "oauth.p256.key"
    assert Path.dirname(path) == Pesque.Storage.keys_dir()

    assert {:ok, priv} = File.read(path)
    assert byte_size(priv) == 32
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert band(mode, 0o777) == 0o600

    assert byte_size(Pesque.OAuth.Keys.keypair().priv) == 32

    # Not named after a DID the way Pesque.Keys names a commit key, and not
    # living in the same file as one.
    refute Pesque.OAuth.Keys.path() == Pesque.Keys.path(Pesque.Identity.did())
  end

  test "the published kid is the RFC 7638 thumbprint of the published key" do
    jwk = Pesque.OAuth.Keys.jwk()

    canonical = ~s({"crv":"P-256","kty":"EC","x":"#{jwk["x"]}","y":"#{jwk["y"]}"})

    assert Pesque.OAuth.Keys.kid() ==
             Base.url_encode64(:crypto.hash(:sha256, canonical), padding: false)
  end

  defp fetch(path), do: dispatch(build_conn(), Endpoint, :get, path, nil)
end
