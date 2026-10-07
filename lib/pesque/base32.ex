defmodule Pesque.Base32 do
  @moduledoc "RFC 4648 base32, lowercase, no padding: the multibase `b` encoding."

  @alphabet ~c"abcdefghijklmnopqrstuvwxyz234567"

  @decode_map Map.new(Enum.with_index(@alphabet))

  def encode(data) when is_binary(data) do
    Base.encode32(data, case: :lower, padding: false)
  end

  def decode!(str) when is_binary(str) do
    chars = String.to_charlist(str)
    bits = length(chars) * 5
    byte_len = div(bits, 8)
    pad_bits = bits - byte_len * 8

    bitstr =
      for c <- chars, into: <<>> do
        case @decode_map do
          %{^c => v} -> <<v::5>>
          _ -> raise ArgumentError, "invalid base32 character: #{<<c>>}"
        end
      end

    <<bin::binary-size(^byte_len), pad::size(^pad_bits)>> = bitstr

    if pad != 0 do
      raise ArgumentError, "non-zero base32 padding bits"
    end

    bin
  end
end
