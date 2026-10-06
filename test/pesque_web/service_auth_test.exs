defmodule PesqueWeb.ServiceAuthTest do
  @moduledoc """
  getServiceAuth: what the minted token claims, and what it refuses to claim.

  The signature is checked against the account's published key rather than
  against whatever key the test can reach for, because "signed with the
  server's secret" is exactly the bug this endpoint exists to avoid.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Keys
  alias Pesque.Secp256k1

  @path "/xrpc/com.atproto.server.getServiceAuth"
  @aud "did:web:relay.example.com"
  @lxm "com.atproto.sync.subscribeRepos"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "the token is signed with the account's key, not the server secret", ctx do
    conn = service_auth(ctx, ctx.token)

    assert conn.status == 200
    token = JSON.decode!(conn.resp_body)["token"]

    assert signed_by_account_key?(token, ctx.alice)
    refute signed_by_server_secret?(token)
  end

  test "the claims carry the account as issuer and the requested audience", ctx do
    claims = claims(service_auth(ctx, ctx.token))

    assert claims["iss"] == ctx.alice.did
    assert claims["aud"] == @aud
    assert is_integer(claims["exp"])
    assert is_integer(claims["iat"])
    refute Map.has_key?(claims, "lxm")
  end

  test "lxm rides along when the caller asks for it", ctx do
    claims = claims(service_auth(ctx, ctx.token, lxm: @lxm))

    assert claims["lxm"] == @lxm
    assert claims["aud"] == @aud
  end

  test "a did#serviceId audience is accepted", ctx do
    aud = "did:plc:abc123#atproto_pds"

    assert service_auth(ctx, ctx.token, aud: aud).status == 200
    assert claims(service_auth(ctx, ctx.token, aud: aud))["aud"] == aud
  end

  test "an audience that is not a DID reference is refused", ctx do
    for aud <- ["relay.example.com", "did:web:", "", "did:web:x.com#", 42] do
      conn = service_auth(ctx, ctx.token, aud: aud)

      assert conn.status == 400, inspect(aud)
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    end
  end

  test "an lxm that is not an NSID is refused", ctx do
    conn = service_auth(ctx, ctx.token, lxm: "not-an-nsid")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "the default expiration is about a minute out", ctx do
    claims = claims(service_auth(ctx, ctx.token))

    assert_in_delta claims["exp"] - System.system_time(:second), 60, 5
  end

  test "an expiration in the past answers BadExpiration", ctx do
    conn = service_auth(ctx, ctx.token, exp: System.system_time(:second) - 60)

    assert conn.status == 400
    assert %{"error" => "BadExpiration"} = JSON.decode!(conn.resp_body)
  end

  test "an expiration that is not an integer answers BadExpiration", ctx do
    for exp <- ["soon", "", "123abc", "1.5", " 60"] do
      conn = service_auth(ctx, ctx.token, exp: exp)

      assert conn.status == 400, inspect(exp)
      assert %{"error" => "BadExpiration"} = JSON.decode!(conn.resp_body)
    end
  end

  # The cap is what keeps this from being a way to mint a long-lived
  # credential for somebody else's service.
  test "an expiration far in the future answers BadExpiration", ctx do
    conn = service_auth(ctx, ctx.token, exp: System.system_time(:second) + 86_400)

    assert conn.status == 400
    assert %{"error" => "BadExpiration"} = JSON.decode!(conn.resp_body)
  end

  test "a requested expiration inside the bounds is honoured exactly", ctx do
    exp = System.system_time(:second) + 120

    assert claims(service_auth(ctx, ctx.token, exp: exp))["exp"] == exp
  end

  # The token is minted for whoever the token says it is, so a missing token
  # cannot ask for one.
  test "getServiceAuth needs an access token", ctx do
    conn = service_auth(ctx, nil)

    assert conn.status == 401
    assert %{"error" => "AuthenticationRequired"} = JSON.decode!(conn.resp_body)
  end

  test "another account's token mints a token for that account", ctx do
    bob = create_account("bob")

    claims = claims(service_auth(ctx, token(bob)))

    assert claims["iss"] == bob.did
    refute claims["iss"] == ctx.alice.did
  end

  test "aud is required", ctx do
    conn = service_auth(ctx, ctx.token, aud: nil)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  defp service_auth(_ctx, jwt, opts \\ []) do
    aud = if Keyword.has_key?(opts, :aud), do: opts[:aud], else: @aud

    query =
      [aud: aud, exp: opts[:exp], lxm: opts[:lxm]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{enc(to_string(value))}" end)

    xrpc_get("#{@path}?#{query}", jwt)
  end

  defp claims(conn) do
    assert conn.status == 200

    conn.resp_body
    |> JSON.decode!()
    |> Map.fetch!("token")
    |> String.split(".")
    |> Enum.fetch!(1)
    |> Base.url_decode64!(padding: false)
    |> JSON.decode!()
  end

  defp signed_by_account_key?(token, user) do
    input = token |> String.split(".") |> Enum.take(2) |> Enum.join(".")
    {:ok, priv} = Keys.load(user.did)
    {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256k1, priv)

    :crypto.verify(
      :ecdsa,
      :sha256,
      input,
      Secp256k1.raw_to_der(signature(token)),
      [pub, :secp256k1]
    )
  end

  defp signed_by_server_secret?(token) do
    # A session token is HS256 over the server secret; a service auth token is
    # ES256K over the account key. Verifying it the session way is what "signed
    # with the wrong key" means.
    match?({:ok, _claims}, Pesque.Token.verify(token, Pesque.Secret.get(), "com.atproto.access"))
  end

  defp signature(token) do
    token
    |> String.split(".")
    |> Enum.fetch!(2)
    |> Base.url_decode64!(padding: false)
  end
end
