defmodule Pesque.Varint do
  @moduledoc "Unsigned LEB128 varints, as used by multihash, CID, and CAR."

  import Bitwise

  def encode(n) when is_integer(n) and n >= 0, do: encode(n, [])

  defp encode(n, acc) when n < 0x80, do: IO.iodata_to_binary(Enum.reverse([n | acc]))
  defp encode(n, acc), do: encode(n >>> 7, [(n &&& 0x7F) ||| 0x80 | acc])

  @doc "Returns {value, rest}."
  def decode(bin), do: decode(bin, 0, 0)

  defp decode(<<b, rest::binary>>, acc, shift) do
    n = acc ||| (b &&& 0x7F) <<< shift
    if b < 0x80, do: {n, rest}, else: decode(rest, n, shift + 7)
  end
end
