defmodule Pesque.Base58Test do
  use ExUnit.Case, async: true

  alias Pesque.Base58

  test "encodes the known vector" do
    assert Base58.encode("hello world") == "StV1DL6CwTryKyV"
  end

  test "round trips binaries" do
    for bin <- [
          <<>>,
          <<0>>,
          <<0, 0, 0>>,
          <<0, 0, 0, 1, 2, 3>>,
          "hello world",
          :crypto.strong_rand_bytes(32)
        ] do
      assert Base58.decode!(Base58.encode(bin)) == bin
    end
  end

  test "preserves leading zero bytes" do
    bin = <<0, 0, 0, 42>>
    assert Base58.encode(bin) == "111" <> Base58.encode(<<42>>)
    assert Base58.decode!(Base58.encode(bin)) == bin
  end

  test "decode! raises on a character outside the alphabet" do
    assert_raise ArgumentError, "invalid base58 character: 0", fn ->
      Base58.decode!("abc0def")
    end

    assert_raise ArgumentError, fn -> Base58.decode!("l") end
    assert_raise ArgumentError, fn -> Base58.decode!("I") end
  end
end
