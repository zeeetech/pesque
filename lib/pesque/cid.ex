defmodule Pesque.CID do
  @moduledoc "CIDv1: version, codec, and a sha2-256 multihash."

  alias Pesque.Varint

  @sha2_256 0x12
  @dag_cbor 0x71
  @raw 0x55

  defstruct version: 1, codec: @dag_cbor, hash_algo: @sha2_256, digest: nil

  def dag_cbor, do: @dag_cbor
  def raw, do: @raw
  def sha2_256, do: @sha2_256

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

  @doc "Parses a base32-multibase CID string. Raises on malformed input."
  def parse("b" <> rest), do: rest |> Pesque.Base32.decode!() |> from_bytes()

  @doc """
  Parses a CID string, or answers :error.

  Raising is right for a CID this server computed and wrong for one a request
  supplied: the raise happens inside whoever is handling the request, so a
  query parameter takes the endpoint down with it. Every HTTP path that reads
  a CID goes through here, not through parse/1.
  """
  def safe_parse(cid) do
    {:ok, parse(cid)}
  rescue
    _ -> :error
  end

  def from_bytes(bin) do
    {version, rest} = Varint.decode(bin)

    if version != 1 do
      raise ArgumentError, "unsupported CID version: #{version}"
    end

    {codec, rest} = Varint.decode(rest)
    {algo, rest} = Varint.decode(rest)
    {len, rest} = Varint.decode(rest)

    case rest do
      <<digest::binary-size(^len)>> ->
        %__MODULE__{codec: codec, hash_algo: algo, digest: digest}

      _ ->
        raise ArgumentError, "malformed CID bytes: truncated digest or trailing garbage"
    end
  end
end
