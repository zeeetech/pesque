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

  @doc """
  The `alg` of a token's header, without checking anything else about it.

  Only the header, so a caller can tell an ES256 access token from an HS256
  session token and pick the verifier to run. Reading the header is not
  trusting it: it is the token's own claim about itself, and the verifier it
  selects checks the signature over the whole token against the published key
  before anything is acted on. A token that does not carry one of the two
  algorithms this server issues is `{:error, :unsupported_alg}` rather than a
  guess, so no token is ever verified as a kind it did not claim to be.
  """
  def alg(token) when is_binary(token) do
    with [header64, _payload, _signature] <- String.split(token, ".", parts: 3),
         {:ok, header} <- decode_segment(header64),
         %{"alg" => alg} when is_binary(alg) <- header do
      {:ok, alg}
    else
      _other -> {:error, :unsupported_alg}
    end
  end

  def alg(_token), do: {:error, :unsupported_alg}

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

  @doc "Encodes a raw 64-byte r || s signature as the DER ECDSA structure :crypto expects."
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

  @doc """
  The uncompressed P-256 public point a JWK names, as `{:ok, <<4, x, y>>}`.

  Both halves have to decode to exactly 32 bytes: a short or long one is not a
  point on this curve, and a point that is not on the curve makes :crypto raise
  rather than answer false. Anything else is `{:error, :invalid_jwk}`.
  """
  def public_key(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y})
      when is_binary(x) and is_binary(y) do
    with {:ok, x} <- Base.url_decode64(x, padding: false),
         {:ok, y} <- Base.url_decode64(y, padding: false),
         true <- byte_size(x) == 32 and byte_size(y) == 32 do
      {:ok, <<4, x::binary, y::binary>>}
    else
      _ -> {:error, :invalid_jwk}
    end
  end

  def public_key(_jwk), do: {:error, :invalid_jwk}

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
  # positive, and that zero has to come off to reach the fixed 32-byte half.
  #
  # A half shorter than 32 bytes is the other case, and the one that matters: a
  # signature value whose top byte is zero is encoded in fewer than 32 bytes,
  # because DER drops leading zero octets, and that is roughly one signature in
  # 128. It has to be zero-extended back to 32 bytes, not stripped. Stripping
  # it produced a 31-byte half, raw_to_der/1 then matched nothing, and every
  # proof carrying such a signature was signed with an empty one and refused.
  defp pad(bin) when byte_size(bin) == 32, do: bin
  defp pad(bin) when byte_size(bin) < 32, do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
  defp pad(<<0, rest::binary>>), do: pad(rest)
  defp pad(bin), do: bin

  defp der_integer(bin) do
    value = drop_zeros(bin)

    case value do
      <<b, _rest::binary>> when (b &&& 0x80) != 0 -> <<0>> <> value
      _ -> value
    end
  end

  # DER drops leading zero octets, so a half whose top byte is already zero
  # encodes as 31 bytes rather than 32. Emitting the 32 bytes anyway is a
  # non-minimal integer, which a strict parser is entitled to refuse, so the
  # zero is dropped here and pad/1 puts it back on the way out.
  defp drop_zeros(<<0, rest::binary>>), do: drop_zeros(rest)
  defp drop_zeros(bin), do: bin
end
