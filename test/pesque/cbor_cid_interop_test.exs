defmodule Pesque.CBORCIDInteropTest do
  use ExUnit.Case, async: true

  alias Pesque.CBOR
  alias Pesque.CID

  test "a cid value encodes as tag 42 over a 0x00 prefixed byte string" do
    cid = CID.from_data(<<1, 2>>)
    payload = CID.to_bytes(cid)

    assert CBOR.encode(%{"l" => cid}) ==
             <<0xA1, 0x61, 0x6C, 0xD8, 0x2A, 0x58, byte_size(payload) + 1, 0x00>> <> payload
  end

  test "a cid value decodes back to an equal struct" do
    cid = CID.from_data(<<1, 2, 3>>)
    term = %{"l" => cid, "n" => 1}

    assert term |> CBOR.encode() |> CBOR.decode!() == term
  end

  test "a bare cid round trips" do
    cid = CID.from_data(<<1, 2, 3>>, CID.raw())

    assert cid |> CBOR.encode() |> CBOR.decode!() == cid
  end

  test "a cid nested in a list round trips" do
    cid = CID.from_data(<<9>>)
    term = [%{"ref" => cid}]

    assert term |> CBOR.encode() |> CBOR.decode!() == term
  end

  test "re-encoding a decoded record reproduces the same bytes" do
    data = CBOR.encode(%{"ref" => CID.from_data(<<1>>), "a" => 1})

    assert data |> CBOR.decode!() |> CBOR.encode() == data
  end
end
