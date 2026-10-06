defmodule Pesque.Car do
  @moduledoc "CAR v1 writer: a dag-cbor header followed by varint-framed blocks."

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Varint

  @doc "roots: list of %CID{}. blocks: %{(%CID{}) => binary}. Returns iodata-ready binary."
  def encode(roots, blocks) when is_list(roots) and is_map(blocks) do
    header = CBOR.encode(%{"version" => 1, "roots" => roots})

    sections =
      blocks
      |> Enum.sort_by(fn {%CID{} = cid, _bytes} -> CID.to_bytes(cid) end)
      |> Enum.map(fn {%CID{} = cid, bytes} ->
        cid_bytes = CID.to_bytes(cid)
        [Varint.encode(byte_size(cid_bytes) + byte_size(bytes)), cid_bytes, bytes]
      end)

    IO.iodata_to_binary([Varint.encode(byte_size(header)), header | sections])
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
