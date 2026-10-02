defmodule Pesque.Base58 do
  @moduledoc "Base58btc encoding (Bitcoin alphabet), as used by multibase `z`."

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  def encode(bin) when is_binary(bin) do
    zeros = leading_zeros(bin, 0)
    chars = encode_int(:binary.decode_unsigned(bin), [])
    IO.iodata_to_binary([List.duplicate(?1, zeros), chars])
  end

  defp leading_zeros(<<0, rest::binary>>, acc), do: leading_zeros(rest, acc + 1)
  defp leading_zeros(_rest, acc), do: acc

  defp encode_int(0, acc), do: acc

  defp encode_int(n, acc) do
    encode_int(div(n, 58), [Enum.fetch!(@alphabet, rem(n, 58)) | acc])
  end

  def decode!(str) when is_binary(str) do
    chars = String.to_charlist(str)
    {ones, rest} = Enum.split_while(chars, &(&1 == ?1))

    n = Enum.reduce(rest, 0, fn c, acc -> acc * 58 + index!(c) end)
    body = if n == 0, do: <<>>, else: :binary.encode_unsigned(n)

    IO.iodata_to_binary([List.duplicate(0, length(ones)), body])
  end

  defp index!(c) do
    case Enum.find_index(@alphabet, &(&1 == c)) do
      nil -> raise ArgumentError, "invalid base58 character: #{<<c>>}"
      i -> i
    end
  end
end
