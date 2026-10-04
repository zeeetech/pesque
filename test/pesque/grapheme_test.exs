defmodule Pesque.GraphemeTest do
  use ExUnit.Case, async: true

  alias Pesque.Grapheme

  @conformance Path.expand("../fixtures/GraphemeBreakTest.txt", __DIR__)

  describe "UAX #29 conformance" do
    # Elixir's String.graphemes/1 fails 7 of these 766: the GB9c Indic conjunct
    # rule for Khmer, Myanmar and Balinese, plus U+2701 ZWJ U+2701 which GB11
    # must not join because U+2701 is not Extended_Pictographic. So a person
    # writing Khmer counts graphemes differently depending on which segmenter
    # they ask, and maxGraphemes enforcement inherits whichever one ships.
    test "split, count and next all agree with GraphemeBreakTest.txt" do
      cases = parse_conformance(@conformance)
      IO.puts("GraphemeBreakTest.txt: #{length(cases)} cases")

      failures =
        for entry <- cases, mismatch = mismatch(entry), mismatch != nil, do: {entry, mismatch}

      assert failures == [],
             "#{length(failures)} of #{length(cases)} conformance cases failed:\n" <>
               Enum.map_join(Enum.take(failures, 20), "\n", fn {entry, mismatch} ->
                 format_failure(entry, mismatch)
               end)
    end
  end

  # The cases that matter in practice, spelled out because the conformance file
  # alone does not record which behaviour anyone depends on. Family emoji,
  # flags, combining marks and Hangul are ones String.graphemes/1 also gets
  # right; the Indic conjuncts below are where it does not.
  describe "sequences that a naive split gets wrong" do
    test "a family ZWJ emoji is one cluster" do
      family = "\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}"
      assert byte_size(family) == 25
      assert Grapheme.count(family) == 1
      assert Grapheme.split(family) == [family]
    end

    test "a regional indicator flag is one cluster" do
      flag = "\u{1F1EC}\u{1F1E7}"
      assert Grapheme.count(flag) == 1
      assert Grapheme.split(flag) == [flag]
    end

    test "regional indicators pair off from the left, three make two clusters" do
      assert Grapheme.count("\u{1F1EC}\u{1F1E7}") == 1
      assert Grapheme.count("\u{1F1EC}\u{1F1E7}\u{1F1E6}") == 2
      assert Grapheme.count("\u{1F1EC}\u{1F1E7}\u{1F1E6}\u{1F1E8}") == 2
      assert Grapheme.count("\u{1F1EC}\u{1F1E7}\u{1F1E6}\u{1F1E8}\u{1F1EA}") == 3
    end

    test "a combining mark stays attached to its base" do
      assert Grapheme.split("e\u{0301}") == ["e\u{0301}"]
      assert Grapheme.count("e\u{0301}") == 1
    end

    test "a Devanagari conjunct joined by a virama is one cluster" do
      # GB9c: InCB=Consonant [Extend Linker]* Linker [Extend Linker]* x Consonant
      ka = "\u{0915}"
      virama = "\u{094D}"
      ssa = "\u{0937}"

      assert Grapheme.count(ka <> virama <> ssa) == 1
      assert Grapheme.split(ka <> virama <> ssa) == [ka <> virama <> ssa]

      # Without the linker it is two clusters, which is what makes the rule a
      # conjunct rule rather than a general "letters never split" rule.
      assert Grapheme.count(ka <> ssa) == 2
    end

    test "a keycap sequence is one cluster" do
      assert Grapheme.count("1\u{FE0F}\u{20E3}") == 1
      assert Grapheme.split("#\u{FE0F}\u{20E3}") == ["#\u{FE0F}\u{20E3}"]
    end

    test "an England flag tag sequence is one cluster" do
      # Black flag plus the tag characters gbeng, terminated by the cancel tag.
      england =
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"

      assert Grapheme.count(england) == 1
      assert Grapheme.split(england) == [england]
    end

    test "a skin tone modifier stays attached" do
      assert Grapheme.count("\u{1F44D}\u{1F3FB}") == 1
      assert Grapheme.split("\u{1F44D}\u{1F3FB}") == ["\u{1F44D}\u{1F3FB}"]
    end

    test "cluster count is not the codepoint count" do
      # The rainbow flag proper: white flag, VS16, ZWJ, rainbow. 5 codepoints,
      # 1 cluster. It needs the ZWJ; without it the two emoji are separate.
      rainbow = "\u{1F3F3}\u{FE0F}‍\u{1F308}"
      assert length(String.codepoints(rainbow)) == 4
      assert Grapheme.count(rainbow) == 1
      assert Grapheme.count("\u{1F3F3}\u{FE0F}\u{1F308}") == 2

      # A mixed string where neither the byte count, the codepoint count nor
      # the cluster count can be guessed from the other.
      mixed = "a" <> "\u{0301}" <> "\u{1F1EC}\u{1F1E7}" <> "\u{1F468}‍\u{1F469}"
      assert length(String.codepoints(mixed)) == 7
      assert byte_size(mixed) == 22
      assert Grapheme.count(mixed) == 3

      assert Grapheme.split(mixed) == [
               "a\u{0301}",
               "\u{1F1EC}\u{1F1E7}",
               "\u{1F468}‍\u{1F469}"
             ]
    end

    test "a Hangul syllable composes across L V T" do
      assert Grapheme.count("\u{1100}\u{1161}\u{11A8}") == 1
      assert Grapheme.count("\u{AC00}\u{11A8}") == 1
    end

    test "CRLF is one cluster and a lone CR is not" do
      assert Grapheme.count("\r\n") == 1
      assert Grapheme.count("a\r\nb") == 3
      assert Grapheme.count("a\rb") == 3
    end
  end

  describe "total on hostile input" do
    test "the empty string has no clusters" do
      assert Grapheme.split("") == []
      assert Grapheme.count("") == 0
      assert Grapheme.next("", 0) == nil
    end

    test "a lone combining mark is its own cluster" do
      assert Grapheme.split("\u{0301}") == ["\u{0301}"]
      assert Grapheme.count("\u{0301}") == 1
    end

    test "a lone ZWJ is its own cluster" do
      zwj = "\u{200D}"
      assert Grapheme.split(zwj) == [zwj]
      assert Grapheme.count(zwj) == 1
    end

    test "a lone regional indicator is its own cluster" do
      ri = "\u{1F1EC}"
      assert Grapheme.split(ri) == [ri]
      assert Grapheme.count(ri) == 1
    end

    test "invalid UTF-8 becomes single byte clusters rather than raising" do
      # A lone continuation byte, a truncated sequence, and a byte that cannot
      # start one.
      assert Grapheme.split(<<0x80>>) == [<<0x80>>]
      assert Grapheme.count(<<0x80>>) == 1

      assert Grapheme.count(<<0xE2, 0x28>>) == 2
      assert Grapheme.split(<<0xE2, 0x28>>) == [<<0xE2>>, <<0x28>>]

      # A lone surrogate encoded as UTF-8 is not well formed either.
      assert Grapheme.count(<<0xED, 0xA0, 0x80>>) == 3

      # Valid text on either side is unaffected.
      assert Grapheme.split("a" <> <<0xFF>> <> "b") == ["a", <<0xFF>>, "b"]
    end

    test "invalid UTF-8 never merges with a combining mark" do
      # The combining mark would attach to a real base character, but there is
      # no base here.
      assert Grapheme.split(<<0xFF>> <> "\u{0301}") == [<<0xFF>>, "\u{0301}"]
    end

    test "the last code point U+10FFFF is handled" do
      max = <<0xF4, 0x8F, 0xBF, 0xBF>>
      assert Grapheme.count(max) == 1
      assert Grapheme.count("a" <> max) == 2
      assert Grapheme.split(max <> "\u{0301}") == [max <> "\u{0301}"]
    end

    test "next/2 handles the degenerate offsets" do
      assert Grapheme.next("abc", -1) == nil
      assert Grapheme.next("abc", 3) == nil
      assert Grapheme.next("abc", 99) == nil
      assert Grapheme.next("", 0) == nil
    end
  end

  describe "next/2" do
    test "resolves an offset inside a cluster to that cluster" do
      input = "a\u{0301}b"
      assert Grapheme.next(input, 0) == {"a\u{0301}", "b"}
      # Offset 1 is inside the first cluster, so it resolves to the same one.
      assert Grapheme.next(input, 1) == {"a\u{0301}", "b"}
      assert Grapheme.next(input, 3) == {"b", ""}
    end

    test "walks the whole string" do
      input = "a\u{0301}\u{1F1EC}\u{1F1E7}b"
      assert walk_with_next(input) == Grapheme.split(input)
    end

    test "returns the rest of the string verbatim" do
      assert {"a", "bcd"} = Grapheme.next("abcd", 0)
      # Every ASCII letter is its own cluster, so the rest is what follows.
      assert {"c", "d"} = Grapheme.next("abcd", 2)
    end
  end

  defp walk_with_next(binary) do
    walk_with_next(binary, 0, [])
  end

  defp walk_with_next(binary, offset, acc) do
    case Grapheme.next(binary, offset) do
      nil -> Enum.reverse(acc)
      {cluster, _rest} -> walk_with_next(binary, offset + byte_size(cluster), [cluster | acc])
    end
  end

  # One case per line of the conformance file.
  #
  # ÷ opens a cluster and closes one, × continues the current one. A line is
  # "÷ 0020 × 0308 ÷", so the expected segmentation is the code points between
  # each pair of ÷ markers, with the leading ÷ contributing nothing.
  defp parse_conformance(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.split(&1, "#", parts: 2))
    |> Stream.reject(fn [line | _] -> String.trim(line) == "" end)
    |> Stream.map(fn [line, comment] ->
      codepoints =
        line |> String.split(~r/[÷×\s]+/, trim: true) |> Enum.map(&String.to_integer(&1, 16))

      %{
        codepoints: codepoints,
        input: utf8(codepoints),
        expected: expected_clusters(line),
        comment: comment
      }
    end)
    |> Enum.to_list()
  end

  defp expected_clusters(line) do
    {clusters, _current} =
      line
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], []}, fn
        # The leading ÷ opens the first cluster rather than closing one.
        "÷", {clusters, []} -> {clusters, []}
        "÷", {clusters, current} -> {[Enum.reverse(current) | clusters], []}
        "×", {clusters, current} -> {clusters, current}
        cp, {clusters, current} -> {clusters, [String.to_integer(cp, 16) | current]}
      end)

    clusters |> Enum.reverse() |> Enum.map(&utf8/1)
  end

  # nil when all three agree with the file, otherwise the function that differs
  # and what it returned.
  defp mismatch(%{input: input, expected: expected}) do
    Enum.find_value(
      [
        {"split", Grapheme.split(input), expected},
        {"count", Grapheme.count(input), length(expected)},
        {"next", walk_with_next(input), expected}
      ],
      fn {name, got, expected} -> if got != expected, do: {name, got} end
    )
  end

  defp utf8(codepoints), do: IO.iodata_to_binary(Enum.map(codepoints, &<<&1::utf8>>))

  defp format_failure(
         %{codepoints: codepoints, input: input, expected: expected, comment: comment},
         {name, got}
       ) do
    "  " <>
      Enum.map_join(codepoints, " U+{", &Integer.to_string(&1, 16)) <>
      "}\n    #{name}:     #{inspect(got)}\n    input:    #{inspect(input)}" <>
      "\n    expected: #{inspect(expected)}\n    #{String.trim(comment)}"
  end
end
