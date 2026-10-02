defmodule Pesque.Tid do
  @moduledoc """
  Timestamp IDs: 13 chars of base32-sortable encoding
  (timestamp_micros <<< 10 ||| clock_id). Monotonic per process via a
  last-value guard, so rapid successive calls never collide.
  """

  import Bitwise

  @alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"

  @doc "Returns {tid_string, integer_value}, strictly greater than `last`."
  def next(last, clock_id) do
    now = System.system_time(:microsecond)
    n = max(last + 1, now <<< 10 ||| clock_id)
    {encode(n), n}
  end

  def encode(n) when is_integer(n) and n >= 0 do
    for i <- 0..12, into: "" do
      <<Enum.fetch!(@alphabet, n >>> (60 - i * 5) &&& 0x1F)>>
    end
  end
end
