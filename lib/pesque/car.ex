defmodule Pesque.Car do
  @moduledoc "CAR v1 writer: a dag-cbor header followed by varint-framed blocks."

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Varint

  @doc "roots: list of %CID{}. blocks: %{(%CID{}) => binary}. Returns iodata-ready binary."
  def encode(roots, blocks) when is_list(roots) and is_map(blocks) do
    IO.iodata_to_binary(Enum.to_list(stream(roots, sort(blocks))))
  end

  @doc """
  The same CAR encode/2 writes, as a lazy stream of chunks: the header first,
  then one chunk per block.

  Blocks are taken in the order the enumerable yields them, not sorted, so a
  caller reading from storage decides the order and no intermediate map of
  every block is needed. The laziness is the point: the blocks enumerable is
  only advanced as each chunk is written, so a caller that pulls one block at a
  time never has the rest of the repo in memory. encode/2 is this same framing
  over sort/1 collected into one binary, which is what keeps the two
  byte-identical: the header, the roots, the block order and the section
  framing are written here once.
  """
  def stream(roots, blocks) when is_list(roots) do
    header = CBOR.encode(%{"version" => 1, "roots" => roots})
    Stream.concat([[Varint.encode(byte_size(header)), header]], Stream.map(blocks, &section/1))
  end

  # Ascending CID, so the order a CAR's blocks come out in does not depend on
  # which map or table they were read from.
  defp sort(blocks) do
    Enum.sort_by(blocks, fn {%CID{} = cid, _bytes} -> CID.to_bytes(cid) end)
  end

  defp section({%CID{} = cid, bytes}) do
    cid_bytes = CID.to_bytes(cid)
    [Varint.encode(byte_size(cid_bytes) + byte_size(bytes)), cid_bytes, bytes]
  end

  @doc """
  Reads a CAR v1 back into `{roots, blocks}`, the shape encode/2 takes.

  The inverse rather than a parser: a CID is only as long as the varints in
  front of its digest say it is, and there is no other way to tell where one
  section's CID ends and its block begins. Sections are therefore required to
  split cleanly, which is what a CAR written by encode/2 does.
  """
  def decode(car) when is_binary(car) do
    {header_len, rest} = Varint.decode(car)
    <<header::binary-size(^header_len), sections::binary>> = rest
    %{"roots" => roots} = CBOR.decode!(header)
    {roots, decode_sections(sections, %{})}
  end

  defp decode_sections(<<>>, acc), do: acc

  defp decode_sections(sections, acc) do
    {len, rest} = Varint.decode(sections)
    <<payload::binary-size(^len), tail::binary>> = rest
    {cid_len, bytes} = split_section(payload)
    <<cid_bytes::binary-size(^cid_len), _::binary>> = payload
    decode_sections(tail, Map.put(acc, CID.from_bytes(cid_bytes), bytes))
  end

  defp split_section(payload) do
    {_version, rest} = Varint.decode(payload)
    {_codec, rest} = Varint.decode(rest)
    {_algo, rest} = Varint.decode(rest)
    {digest_len, rest} = Varint.decode(rest)
    cid_len = byte_size(payload) - byte_size(rest) + digest_len
    <<_cid::binary-size(^cid_len), bytes::binary>> = payload
    {cid_len, bytes}
  end
end
