defmodule Pesque.OAuth.Jwt do
  @moduledoc """
  Compact JWS in ES256, for the two token kinds OAuth uses here.

  Same shape as Pesque.Token and for the same reason: the encoding is three
  base64url segments and nothing about it needs a library. What differs is the
  signature. A session token is HS256 because only this server checks it; a
  DPoP proof and an access token are ES256, signed with the key in
  Pesque.OAuth.Keys and published in the JWKS, so whoever holds the token can
  check it against this server's published keys.
  """

  import Bitwise

  @curve :secp256r1

  @doc "Signs `claims` into a compact JWS. `priv` is a 32-byte P-256 scalar."
  def sign_es256(claims, priv, kid) do
    header = %{"alg" => "ES256", "typ" => "JWT", "kid" => kid}
    input = encode(JSON.encode!(header)) <> "." <> encode(JSON.encode!(claims))
    input <> "." <> encode(sign_raw(input, priv))
  end

  @doc """
  Splits a compact JWS into its parts without checking anything.

  The signature comes back as the caller handed it over, raw r || s, because
  that is the form JWS uses and the only form that can be turned back into the
  DER ECDSA structure :crypto.verify/5 expects.
  """
  def decode(token) when is_binary(token) do
    with [header64, payload64, signature64] <- String.split(token, ".", parts: 3),
         {:ok, signature} <- Base.url_decode64(signature64, padding: false),
         {:ok, header} <- decode_segment(header64),
         {:ok, claims} <- decode_segment(payload64) do
      {:ok, header, claims, header64 <> "." <> payload64, signature}
    else
      _ -> {:error, :malformed_jwt}
    end
  end

  def decode(_token), do: {:error, :malformed_jwt}

  # Never the bang version: a DPoP proof and a client assertion both arrive
  # from a stranger, and a raise here is a 500 on a request that was simply
  # malformed. The header has to be an object and the payload a map of claims,
  # which is what the callers below assume.
  defp decode_segment(segment) do
    with {:ok, bin} <- Base.url_decode64(segment, padding: false),
         {:ok, decoded} <- JSON.decode(bin) do
      if is_map(decoded), do: {:ok, decoded}, else: {:error, :malformed_jwt}
    end
  end

  @doc "The ES256 signature of `input` as raw 64-byte r || s."
  def sign_raw(input, priv) do
    der_to_raw(:crypto.sign(:ecdsa, :sha256, input, [priv, @curve]))
  end

  @doc """
  Whether `signature` (raw r || s) is a valid ES256 signature of `input` under
  the public point `pub`.

  A point that is not on the curve makes :crypto raise rather than answer
  false, and the point arrives inside an untrusted proof, so it is caught here
  and answered as a failed verification.
  """
  def verify_es256(input, signature, pub) do
    :crypto.verify(:ecdsa, :sha256, input, raw_to_der(signature), [pub, @curve])
  rescue
    _ -> false
  end

  @doc """
  RFC 7638 thumbprint of an EC public JWK, base64url.

  The member order is written out rather than left to the JSON encoder,
  because the thumbprint is a hash of a specific byte sequence and an encoder
  that reorders members would produce a different one.
  """
  def thumbprint(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y})
      when is_binary(x) and is_binary(y) do
    members = ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})
    encode(:crypto.hash(:sha256, members))
  end

  def thumbprint(_jwk), do: {:error, :unsupported_jwk}

  @doc "Encodes a public point as the JWK members a JWKS carries."
  def raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    rb = der_integer(r)
    sb = der_integer(s)
    body = <<0x02, byte_size(rb)>> <> rb <> <<0x02, byte_size(sb)>> <> sb
    <<0x30, byte_size(body)>> <> body
  end

  def raw_to_der(_signature), do: <<>>

  @doc "The JWK members of an uncompressed P-256 public point."
  def public_jwk(<<4, x::binary-32, y::binary-32>>) do
    %{"kty" => "EC", "crv" => "P-256", "x" => encode(x), "y" => encode(y)}
  end

  def encode(bin), do: Base.url_encode64(bin, padding: false)

  # A DER ECDSA signature is SEQUENCE { INTEGER r, INTEGER s }. Both integers
  # are unsigned and at most 33 bytes here: 32, or 33 when the high bit is set
  # and the encoding needs a leading zero to stay positive.
  defp der_to_raw(
         <<0x30, _len, 0x02, rlen, r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>>
       ) do
    pad(r) <> pad(s)
  end

  # A DER INTEGER over 32 bytes carries a leading zero so the value stays
  # positive, and that zero has to come off to reach the fixed 32-byte half. The
  # size is checked first: a half whose top byte really is zero is a 32-byte
  # half, not a 33-byte one with padding to remove.
  defp pad(bin) when byte_size(bin) == 32, do: bin
  defp pad(<<0, rest::binary>>), do: pad(rest)
  defp pad(bin), do: bin

  defp der_integer(bin) do
    case bin do
      <<b, _rest::binary>> when (b &&& 0x80) != 0 -> <<0>> <> bin
      _ -> bin
    end
  end
end
