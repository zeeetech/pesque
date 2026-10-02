defmodule Pesque.CID do
  @moduledoc "CIDv1: version, codec, and a sha2-256 multihash."

  alias Pesque.Varint

  @sha2_256 0x12
  @dag_cbor 0x71
  @raw 0x55

  defstruct version: 1, codec: @dag_cbor, hash_algo: @sha2_256, digest: nil

  def dag_cbor, do: @dag_cbor
  def raw, do: @raw

  @doc "Builds a CIDv1 for `data` under the given codec (default dag-cbor)."
  def from_data(data, codec \\ @dag_cbor) do
    %__MODULE__{codec: codec, digest: :crypto.hash(:sha256, data)}
  end

  def to_bytes(%__MODULE__{} = cid) do
    Varint.encode(cid.version) <>
      Varint.encode(cid.codec) <>
      Varint.encode(cid.hash_algo) <>
      Varint.encode(byte_size(cid.digest)) <>
      cid.digest
  end

  def to_string(cid), do: "b" <> Pesque.Base32.encode(to_bytes(cid))

  @doc "Parses a base32-multibase CID string."
  def parse("b" <> rest), do: rest |> Pesque.Base32.decode!() |> from_bytes()

  def from_bytes(bin) do
    {1, rest} = Varint.decode(bin)
    {codec, rest} = Varint.decode(rest)
    {algo, rest} = Varint.decode(rest)
    {len, rest} = Varint.decode(rest)
    <<digest::binary-size(^len)>> = rest

    %__MODULE__{codec: codec, hash_algo: algo, digest: digest}
  end
end
