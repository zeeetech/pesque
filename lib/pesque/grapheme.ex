defmodule Pesque.Grapheme do
  @moduledoc """
  Extended grapheme cluster segmentation, as defined by UAX #29 section 3.1,
  rules GB1 through GB13 and GB999 (Unicode 17.0.0, UAX #29 revision 47).

  A grapheme cluster is what a reader thinks of as one character: a base letter
  plus its combining marks, a flag, an emoji ZWJ sequence.

  `String.graphemes/1` is close but not exact. It passes 759 of the 766 cases in
  `GraphemeBreakTest.txt` on this toolchain; it misses the GB9c Indic conjunct
  rule, so a Khmer, Myanmar or Balinese cluster split by a consonant linker
  counts as more than one, and it joins U+2701 ZWJ U+2701 that GB11 must leave
  apart. Emoji, flags, combining marks and Hangul, the cases most strings are
  made of, it gets right.

  This exists to enforce the `maxGraphemes` constraint in lexicon validators,
  where the unit has to be the one the protocol means, and to be exactly that
  unit rather than nearly.

      iex> Pesque.Grapheme.split("a\\u0301b")
      ["a\\u0301", "b"]

  Depends only on `Pesque.Grapheme.Tables` and the standard library, so the
  directory can be lifted out as a standalone package.
  """

  alias Pesque.Grapheme.Tables

  # Three of the rules need facts about the text before the current code point
  # that the previous code point alone does not carry, so each is a small
  # forward scan whose result is carried in the state:
  #
  #   gcb     the previous Grapheme_Cluster_Break value, for GB3 to GB9b.
  #   ep      how far a GB11 emoji ZWJ match has got: :none, :ep_seen while the
  #           text reads Extended_Pictographic Extend*, :zwj_after_ep once the
  #           ZWJ lands.
  #   incb    how far a GB9c conjunct match has got: :none, :consonant while the
  #           text reads Consonant [Extend Linker]*, :linked once a Linker has
  #           been seen.
  #   ri_run  the length of the run of Regional_Indicator immediately
  #           preceding, which GB12 and GB13 need for their parity test.
  #
  # :other rather than a sentinel so the initial value satisfies no rule, which
  # is what makes the first code point a GB1 break on its own.
  @state {:other, :none, :none, 0}

  @typedoc "The cluster covering a byte offset, and everything after it."
  @type next_result :: {binary, binary} | nil

  @doc """
  The extended grapheme clusters of `binary`, in order.

      iex> Pesque.Grapheme.split("\\u{1F1EC}\\u{1F1E7}")
      ["\\u{1F1EC}\\u{1F1E7}"]

  Invalid UTF-8 does not raise. A byte that does not begin a well formed UTF-8
  sequence becomes a single byte cluster of its own, since there is no
  character to attach it to.
  """
  @spec split(binary) :: [binary]
  def split(binary) when is_binary(binary), do: split(binary, binary, 0, 0, @state, [])

  @doc """
  The number of extended grapheme clusters in `binary`.

  The same traversal as `split/1` with nothing accumulated, so a long string
  costs no memory beyond the input.
  """
  @spec count(binary) :: non_neg_integer
  def count(binary) when is_binary(binary), do: count(binary, binary, 0, 0, @state, 0)

  @doc """
  The cluster covering byte `offset` in `binary`, and the rest of the string.

      iex> Pesque.Grapheme.next("a\\u0301b", 0)
      {"a\\u0301", "b"}

  `offset` need not sit on a cluster boundary; it resolves to the cluster that
  covers it. To walk a string, start at 0 and advance by the size of each
  cluster returned.

  Returns `nil` when `offset` is negative or at or past the end of the string.
  """
  @spec next(binary, integer) :: next_result()
  def next(binary, offset) when is_binary(binary) and is_integer(offset) and offset >= 0 do
    if offset < byte_size(binary), do: locate(binary, binary, 0, 0, @state, offset)
  end

  def next(_binary, _offset), do: nil

  # Whether a boundary falls before `cp`, given the state of the text before it,
  # plus the state to carry into the next code point.
  #
  # The rules are one ordered cond rather than independent predicates because
  # UAX #29 takes the first rule that matches: GB4 ending a match that GB11
  # would otherwise continue is the intended reading, not an oversight.
  defp advance(_state, :invalid), do: {true, {:invalid, :none, :none, 0}}

  defp advance({gcb, ep, incb, ri_run}, cp) do
    cur = Tables.gcb(cp)

    break? =
      cond do
        # GB3. A CRLF pair is one newline, not two clusters.
        gcb == :cr and cur == :lf -> false
        # GB4 and GB5. Controls stand alone on both sides, which also ends any
        # multi code point match that reached this far.
        gcb in [:control, :cr, :lf, :invalid] -> true
        cur in [:control, :cr, :lf, :invalid] -> true
        # GB6, GB7, GB8. Hangul syllables compose L V T.
        gcb == :l and cur in [:l, :v, :lv, :lvt] -> false
        gcb in [:lv, :v] and cur in [:v, :t] -> false
        gcb in [:lvt, :t] and cur == :t -> false
        # GB9. Combining marks and ZWJ attach to whatever precedes them.
        cur in [:extend, :zwj] -> false
        # GB9a and GB9b. Spacing marks attach forward, prepend characters attach
        # backward.
        cur == :spacing_mark -> false
        gcb == :prepend -> false
        # GB9c. An Indic consonant joined to the next one by a linker stays a
        # single cluster, which is how a consonant, virama and consonant render
        # as one conjunct rather than three letters. Only :linked means a
        # linker was actually seen; see step_incb/2 for why carrying that
        # forward is equivalent to scanning backwards over what came before.
        incb == :linked and Tables.incb(cp) == :consonant -> false
        # GB11. Emoji ZWJ sequences, Extended_Pictographic Extend* ZWJ x
        # Extended_Pictographic.
        ep == :zwj_after_ep and Tables.extended_pictographic?(cp) -> false
        # GB12 and GB13. Regional indicators pair off from the left, so a flag
        # is two of them. The run length before the break point decides: odd
        # keeps the pair together, even starts a new flag.
        gcb == :regional_indicator and cur == :regional_indicator and rem(ri_run, 2) == 1 -> false
        # GB999. Everything else breaks.
        true -> true
      end

    {break?, {cur, step_ep(ep, cp), step_incb(incb, cp), step_ri(ri_run, cur)}}
  end

  # GB11. The Extend* in the rule is Grapheme_Cluster_Break=Extend, which ZWJ
  # is not, so the ZWJ gets its own case, and anything other than
  # Extended_Pictographic after the ZWJ restarts the match.
  defp step_ep(ep, cp) do
    cond do
      Tables.extended_pictographic?(cp) -> :ep_seen
      Tables.gcb(cp) == :extend and ep == :ep_seen -> :ep_seen
      Tables.gcb(cp) == :zwj and ep == :ep_seen -> :zwj_after_ep
      true -> :none
    end
  end

  # GB9c, for Consonant [Extend Linker]* Linker [Extend Linker]*.
  #
  # The rule reads as a scan backwards over code points already seen. Carrying
  # this three state machine forwards is equivalent, and the UCD guarantees it:
  # every code point with InCB=Extend or InCB=Linker also has
  # Grapheme_Cluster_Break of Extend, ZWJ or SpacingMark, and GB9 and GB9a
  # forbid a break before all three. A boundary therefore can never fall
  # strictly inside a run of them, so the state cannot leak across one. Any
  # other code point resets to :none, which is exactly where such a boundary
  # would have fallen. The scan is bounded by the preceding break by
  # construction.
  defp step_incb(incb, cp) do
    case Tables.incb(cp) do
      # A consonant both ends any previous match and starts a new one.
      :consonant -> :consonant
      # A linker only counts after a consonant, which is the whole difference
      # between :consonant and :none here.
      :linker -> if incb == :consonant or incb == :linked, do: :linked, else: :none
      # An Extend keeps the match open without advancing it.
      :extend -> incb
      :none -> :none
    end
  end

  defp step_ri(ri_run, cur) do
    if cur == :regional_indicator, do: ri_run + 1, else: 0
  end

  # split/1. `whole` is the input, for slicing; `rest` is what is left of it.
  # `pos` is the byte offset of `rest` within `whole`, `cluster_start` the
  # offset the current cluster began at.
  #
  # Closed clusters are prepended to acc, so the base case reverses once.
  # The empty-tail clause with pos == cluster_start is how the empty string
  # yields no clusters rather than one empty one.
  defp split(<<>>, whole, pos, cluster_start, _state, acc) when pos > cluster_start do
    Enum.reverse([binary_part(whole, cluster_start, pos - cluster_start) | acc])
  end

  defp split(<<>>, _whole, _pos, _cluster_start, _state, acc), do: Enum.reverse(acc)

  defp split(rest, whole, pos, cluster_start, state, acc) do
    {cp, size, tail} = decode(rest)
    {break?, state} = advance(state, cp)

    # The break before the first code point is GB1, and pos > cluster_start is
    # what keeps it from emitting an empty cluster.
    acc =
      if break? and pos > cluster_start do
        [binary_part(whole, cluster_start, pos - cluster_start) | acc]
      else
        acc
      end

    split(tail, whole, pos + size, if(break?, do: pos, else: cluster_start), state, acc)
  end

  # count/1. The traversal split/1 does, with the accumulator dropped. The count
  # is one more than the number of boundaries seen, because a string with N
  # boundaries has N + 1 clusters. The empty string has neither.
  defp count(<<>>, _whole, pos, cluster_start, _state, count) do
    if pos > cluster_start, do: count + 1, else: count
  end

  defp count(rest, whole, pos, cluster_start, state, count) do
    {cp, size, tail} = decode(rest)
    {break?, state} = advance(state, cp)

    count(
      tail,
      whole,
      pos + size,
      if(break?, do: pos, else: cluster_start),
      state,
      if(break? and pos > cluster_start, do: count + 1, else: count)
    )
  end

  # next/2. Resolving an arbitrary offset means segmenting from the start
  # anyway, since GB12 in particular depends on how many regional indicators
  # precede the offset. So walk until a boundary closes a cluster that covers
  # the offset.
  defp locate(<<>>, whole, pos, cluster_start, _state, _offset) do
    {binary_part(whole, cluster_start, pos - cluster_start), ""}
  end

  defp locate(rest, whole, pos, cluster_start, state, offset) do
    {cp, size, tail} = decode(rest)

    # advance/2 always breaks around a malformed byte and resets the state after
    # it, which is what makes the byte its own cluster.
    {break?, state} = advance(state, cp)

    # This boundary closes the cluster that began at cluster_start. If it
    # covers the offset, that closed cluster is the answer.
    if break? and pos > cluster_start and offset < pos do
      {binary_part(whole, cluster_start, pos - cluster_start),
       binary_part(whole, pos, byte_size(whole) - pos)}
    else
      locate(tail, whole, pos + size, if(break?, do: pos, else: cluster_start), state, offset)
    end
  end

  # One code point as {codepoint | :invalid, byte_size, remainder}.
  #
  # The second clause is what makes the module total: a byte that does not start
  # a well formed sequence comes back as :invalid rather than raising.
  defp decode(<<cp::utf8, rest::binary>>), do: {cp, byte_size(<<cp::utf8>>), rest}
  defp decode(<<_byte, rest::binary>>), do: {:invalid, 1, rest}
end
