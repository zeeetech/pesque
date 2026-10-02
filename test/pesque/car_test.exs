defmodule Pesque.CarTest do
  use ExUnit.Case, async: true

  alias Pesque.{CBOR, CID, Car, Varint}

  setup do
    root = CID.from_data(CBOR.encode(%{"did" => "did:web:localhost"}))

    blocks =
      for i <- 0..2, into: %{} do
        {CID.from_data(CBOR.encode(%{"i" => i})), CBOR.encode(%{"i" => i})}
      end

    %{root: root, blocks: blocks}
  end

  test "returns a binary", context do
    assert is_binary(car(context))
  end

  test "the header is a varint length followed by the dag-cbor header", context do
    {header, sections, _total} = parse(car(context))

    assert CBOR.decode!(header) == %{"version" => 1, "roots" => [context.root]}
    assert length(sections) == map_size(context.blocks)
  end

  test "each section length covers the cid bytes and the block bytes", context do
    {_header, sections, _total} = parse(car(context))

    for {{declared_len, actual_len}, cid, bytes} <- sections do
      assert declared_len == actual_len
      assert actual_len == byte_size(CID.to_bytes(cid)) + byte_size(bytes)
    end
  end

  test "slices round trip back to the original blocks", context do
    {_header, sections, _total} = parse(car(context))

    # parse/1 slices the cid off the front of each section payload, so the
    # remainder is the trailing block bytes.
    recovered = Map.new(sections, fn {_lens, cid, trailing} -> {cid, trailing} end)

    assert recovered == context.blocks
  end

  test "the total length is the sum of its parts", context do
    {header, sections, total} = parse(car(context))

    sections_len =
      Enum.reduce(sections, 0, fn {{_declared_len, actual_len}, _cid, _bytes}, acc ->
        acc + byte_size(Varint.encode(actual_len)) + actual_len
      end)

    header_len = byte_size(header)

    assert total == byte_size(Varint.encode(header_len)) + header_len + sections_len
  end

  test "an empty block map yields header only", %{root: root} do
    {header_len, rest} = Varint.decode(Car.encode([root], %{}))

    assert <<_header::binary-size(^header_len), "">> = rest
  end

  defp car(context), do: Car.encode([context.root], context.blocks)

  # Returns {header_bytes, [{{declared_len, section_len}, cid, block}], total_len}
  defp parse(car) do
    {header_len, rest} = Varint.decode(car)
    <<header::binary-size(^header_len), sections::binary>> = rest

    entries =
      Enum.map(split_sections(sections), fn {declared_len, payload} ->
        cid_len = cid_byte_size(payload)
        <<cid_bytes::binary-size(^cid_len), bytes::binary>> = payload
        {{declared_len, byte_size(payload)}, CID.from_bytes(cid_bytes), bytes}
      end)

    {header, entries, byte_size(car)}
  end

  # A CIDv1 is four varints (version, codec, hash algo, digest length) then the digest.
  defp cid_byte_size(bin) do
    {_version, rest1} = Varint.decode(bin)
    {_codec, rest2} = Varint.decode(rest1)
    {_algo, rest3} = Varint.decode(rest2)
    {digest_len, rest4} = Varint.decode(rest3)

    byte_size(bin) - byte_size(rest4) + digest_len
  end

  defp split_sections(<<>>), do: []

  defp split_sections(bin) do
    {len, rest} = Varint.decode(bin)
    <<payload::binary-size(^len), tail::binary>> = rest
    [{len, payload} | split_sections(tail)]
  end
end
