defmodule Pesque.Secp256k1 do
  @moduledoc """
  secp256k1 helpers: point compression, multibase public keys, and
  ECDSA signatures in the exact shape ATProto expects (raw, low-S).
  """

  import Bitwise

  # varint encoding of multicodec secp256k1-pub (0xE7)
  @multicodec_prefix <<0xE7, 0x01>>

  @group_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @doc "Generates {compressed_public_key, private_key}."
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256k1)
    {compress(pub), priv}
  end

  @doc "Re-derives the compressed public key for a stored private key."
  def public_from_private(priv) do
    {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256k1, priv)
    compress(pub)
  end

  @doc "Uncompressed point (0x04 <> x <> y) to SEC compressed form."
  def compress(<<4, x::binary-32, y::binary-32>>) do
    prefix = if rem(:binary.decode_unsigned(y), 2) == 0, do: 0x02, else: 0x03
    <<prefix, x::binary>>
  end

  @doc "`publicKeyMultibase` value for a compressed secp256k1 key."
  def public_key_multibase(compressed_pub) do
    "z" <> Pesque.Base58.encode(@multicodec_prefix <> compressed_pub)
  end

  @doc "ECDSA/SHA-256 over payload, returned as raw r || s with low-S normalization."
  def sign(priv, payload) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [priv, :secp256k1])
    der_to_raw(der)
  end

  @doc "DER sequence to fixed 64-byte r || s, folding high-S into low-S."
  def der_to_raw(
        <<0x30, _len, 0x02, rlen, r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>>
      ) do
    r_int = :binary.decode_unsigned(r)

    s_int =
      case :binary.decode_unsigned(s) do
        s when s > div(@group_order, 2) -> @group_order - s
        s -> s
      end

    <<r_int::big-256, s_int::big-256>>
  end

  @doc "Inverse of der_to_raw/1, for when you need to verify with :crypto."
  def raw_to_der(<<r::big-256, s::big-256>>) do
    rb = der_integer(r)
    sb = der_integer(s)
    body = <<0x02, byte_size(rb)>> <> rb <> <<0x02, byte_size(sb)>> <> sb
    <<0x30, byte_size(body)>> <> body
  end

  defp der_integer(int) do
    bin = :binary.encode_unsigned(int)

    case bin do
      <<b, _rest::binary>> when (b &&& 0x80) != 0 -> <<0>> <> bin
      _ -> bin
    end
  end
end
