defmodule Pesque.Tid do
  @moduledoc """
  Timestamp IDs: 13 chars of base32-sortable encoding
  (timestamp_micros <<< 10 ||| clock_id). Two calls with the same `last` can
  answer the same value, because both read the same clock. Strict increase
  comes from threading the integer the previous call returned back in as
  `last`, which is how the repo writes use it.
  """

  import Bitwise

  @alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"

  @doc "Returns {tid_string, integer_value}, strictly greater than `last`."
  def next(last, clock_id) when is_integer(clock_id) and clock_id >= 0 and clock_id <= 1023 do
    now = System.system_time(:microsecond)
    n = max(last + 1, now <<< 10 ||| clock_id)
    {encode(n), n}
  end

  @doc "Encodes an integer as the 13-char sortable form. The encoding is only defined up to 64 bits."
  def encode(n) when is_integer(n) and n >= 0 do
    for i <- 0..12, into: "" do
      <<Enum.fetch!(@alphabet, n >>> (60 - i * 5) &&& 0x1F)>>
    end
  end
end
