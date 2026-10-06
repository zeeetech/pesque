defmodule Pesque.OAuth.JwtTest do
  @moduledoc """
  The ES256 encoding, which is the one piece here a browser client cannot see
  the inside of.

  A JWT is only useful if somebody else's verifier accepts it, so these are
  round trips against `:crypto` rather than against this module's own encoder:
  signing then verifying with the OTP primitives, and thumbprints checked
  against the RFC 7638 worked example.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Jwt

  setup do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{pub: pub, priv: priv, input: "header.payload"}
  end

  test "a signature this module produces verifies with :crypto", ctx do
    signature = Jwt.sign_raw(ctx.input, ctx.priv)

    assert byte_size(signature) == 64

    assert :crypto.verify(:ecdsa, :sha256, ctx.input, Jwt.raw_to_der(signature), [
             ctx.pub,
             :secp256r1
           ])
  end

  test "verify_es256/3 agrees with :crypto in both directions", ctx do
    signature = Jwt.sign_raw(ctx.input, ctx.priv)

    assert Jwt.verify_es256(ctx.input, signature, ctx.pub)
    refute Jwt.verify_es256("other.payload", signature, ctx.pub)
  end

  test "a signature made by another key does not verify", ctx do
    {_other_pub, other_priv} = :crypto.generate_key(:ecdh, :secp256r1)

    refute Jwt.verify_es256(ctx.input, Jwt.sign_raw(ctx.input, other_priv), ctx.pub)
  end

  # A public point that is not on the curve makes :crypto raise rather than
  # answer false, and a DPoP proof carries its own key, so this has to be a
  # failed verification and not a 500.
  test "a point that is not on the curve fails rather than raising" do
    point = <<4>> <> :binary.copy(<<9>>, 32) <> :binary.copy(<<9>>, 32)

    refute Jwt.verify_es256("input", :binary.copy(<<1>>, 64), point)
  end

  test "a malformed signature fails rather than raising", ctx do
    refute Jwt.verify_es256(ctx.input, <<1, 2, 3>>, ctx.pub)
    refute Jwt.verify_es256(ctx.input, :binary.copy(<<0>>, 32), ctx.pub)
  end

  test "sign and decode round trip the claims" do
    claims = %{"sub" => "did:web:example.com", "exp" => 1_800_000_000, "cnf" => %{"jkt" => "abc"}}

    token = Jwt.sign_es256(claims, :crypto.generate_key(:ecdh, :secp256r1) |> elem(1), "kid-1")

    assert {:ok, header, decoded, _input, signature} = Jwt.decode(token)
    assert header["alg"] == "ES256"
    assert header["typ"] == "JWT"
    assert header["kid"] == "kid-1"
    assert decoded == claims
    assert byte_size(signature) == 64
  end

  test "decode answers a reason rather than raising on anything a stranger sends" do
    for token <- ["", "a", "a.b", "a.b.c", "....", "%%%.%%%.%%%", String.duplicate("x", 500)] do
      assert {:error, :malformed_jwt} = Jwt.decode(token)
    end
  end

  test "a JSON array in a segment is not claims" do
    token = "WzFd.WzFd.AAAA"

    assert {:error, :malformed_jwt} = Jwt.decode(token)
  end

  test "the RFC 7638 worked example thumbprints to the published value" do
    # The example from RFC 7638 appendix A, an RSA key, to prove the canonical
    # member ordering is what the RFC asks for rather than this module's taste.
    jwk = %{
      "kty" => "RSA",
      "n" =>
        "0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64tZ_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2QvzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbOpbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw",
      "e" => "AQAB",
      "alg" => "RS256",
      "kid" => "2011-04-29"
    }

    canonical =
      ~s({"e":"#{jwk["e"]}","kty":"RSA","n":"#{jwk["n"]}"})

    assert Base.url_encode64(:crypto.hash(:sha256, canonical), padding: false) ==
             "NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs"
  end

  test "an EC thumbprint hashes only the four required members" do
    {point, _priv} = :crypto.generate_key(:ecdh, :secp256r1)

    bare = Jwt.public_jwk(point)
    full = Map.merge(bare, %{"kid" => "k", "alg" => "ES256", "use" => "sig"})

    assert Jwt.thumbprint(bare) == Jwt.thumbprint(full)
  end

  test "a key that is not a P-256 EC key has no thumbprint here" do
    for jwk <- [
          %{},
          %{"kty" => "EC", "crv" => "P-384", "x" => "a", "y" => "b"},
          %{"kty" => "RSA", "n" => "a", "e" => "AQAB"},
          %{"kty" => "EC", "crv" => "P-256", "x" => 1, "y" => "b"}
        ] do
      assert {:error, :unsupported_jwk} = Jwt.thumbprint(jwk)
    end
  end
end
