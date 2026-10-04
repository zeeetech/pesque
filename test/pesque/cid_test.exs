defmodule Pesque.CIDTest do
  use ExUnit.Case, async: true

  alias Pesque.CBOR
  alias Pesque.CID

  test "matches the cids computed by the reference ipld implementation" do
    assert %{"a" => 1} |> CBOR.encode() |> CID.from_data() |> CID.to_string() ==
             "bafyreihltcnuuyqp2jm24aqydpnlj7b6w3ogwrplomrjtg5rifv44mmjey"

    assert %{"hello" => "world"} |> CBOR.encode() |> CID.from_data() |> CID.to_string() ==
             "bafyreidykglsfhoixmivffc5uwhcgshx4j465xwqntbmu43nb2dzqwfvae"
  end

  test "from_data defaults to dag-cbor and accepts raw" do
    assert CID.from_data(<<1>>).codec == CID.dag_cbor()
    assert CID.from_data(<<1>>, CID.raw()).codec == CID.raw()

    assert CID.dag_cbor() == 0x71
    assert CID.raw() == 0x55
  end

  test "round trips the binary form" do
    for codec <- [CID.dag_cbor(), CID.raw()] do
      cid = CID.from_data(:crypto.strong_rand_bytes(32), codec)
      assert CID.from_bytes(CID.to_bytes(cid)) == cid
    end
  end

  test "round trips the string form" do
    cid = CID.from_data(<<1, 2, 3>>, CID.raw())

    assert CID.parse(CID.to_string(cid)) == cid
  end

  test "to_bytes is version, codec, multihash" do
    cid = CID.from_data(<<1, 2, 3>>)

    assert CID.to_bytes(cid) ==
             <<0x01, 0x71, 0x12, 0x20>> <> :crypto.hash(:sha256, <<1, 2, 3>>)
  end

  test "to_string is base32 lower with a b prefix" do
    assert String.starts_with?(CID.to_string(CID.from_data(<<1>>)), "b")
  end

  # parse/1 raises, and every one of these shapes made it raise. They come
  # from a query string or a record body, so the endpoint reading them must
  # not be the one to die.
  test "safe_parse answers :error on everything that makes parse raise" do
    for bad <- ["bafkrei", "b", "", "not a cid", "bafkre!", "bmfxxxxxxxx", "zzzz", nil, 42] do
      assert CID.safe_parse(bad) == :error, inspect(bad)
    end
  end

  test "safe_parse answers :error on a non-base32 string and on a truncated cid" do
    assert CID.safe_parse("bafyrei") == :error

    assert CID.safe_parse(
             String.slice("bafyreiauu4dlrmesbnb7i24u7niyunmpxb6bg4dmpo7ul7wnslx5b77gf4", 0, 20)
           ) == :error
  end

  test "safe_parse answers the same struct parse does on input that decodes" do
    cid = CID.from_data(<<1, 2, 3>>, CID.raw())

    assert CID.safe_parse(CID.to_string(cid)) == {:ok, cid}
  end

  # Parsing is not validating, and this is the shape that proves it: a CID
  # that decodes to a raw codec with no hash algorithm and an empty digest,
  # which parse/1 is perfectly happy to return. It is why callers that build a
  # path from a CID match on the struct instead of trusting the string.
  test "safe_parse is not validation: garbage that decodes comes back as a struct" do
    assert {:ok, cid} = CID.safe_parse("bafkqaaa")
    assert cid.codec == CID.raw()
    assert cid.hash_algo == 0
    assert cid.digest == ""

    assert {:ok, dag_cbor} =
             CID.safe_parse("bafyreidykglsfhoixmivffc5uwhcgshx4j465xwqntbmu43nb2dzqwfvae")

    assert dag_cbor.codec == CID.dag_cbor()
  end
end
