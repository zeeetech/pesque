defmodule Mix.Tasks.Pesque.GenUnicode do
  @shortdoc "Regenerates the Unicode property tables behind Pesque.Grapheme."

  @moduledoc """
  Reads the Unicode Character Database files the grapheme segmenter needs and
  writes `lib/pesque/grapheme/tables.ex`.

      mix pesque.gen_unicode              # downloads from unicode.org
      mix pesque.gen_unicode path/to/ucd  # reads from a local UCD checkout

  Three properties are extracted:

    * `Grapheme_Cluster_Break` from `auxiliary/GraphemeBreakProperty.txt`, the
      primary segmentation property. Unlisted code points are `Other`.
    * `Extended_Pictographic` from `emoji/emoji-data.txt`, needed only by GB11.
      It is not derivable from `Grapheme_Cluster_Break`.
    * `Indic_Conjunct_Break` from `DerivedCoreProperties.txt`, needed only by
      GB9c. Unlisted code points are `None`.

  The generated module is committed, so the server never fetches anything and
  never needs the UCD at runtime. This task exists so the tables can be
  rebuilt when the pinned Unicode version moves.

  An offline run reads `auxiliary/GraphemeBreakProperty.txt`,
  `emoji/emoji-data.txt`, and `DerivedCoreProperties.txt` from the given
  directory, which should be the UCD root, so pass the directory that
  contains `auxiliary/` and `emoji/`.

  """

  use Mix.Task

  @version "17.0.0"

  @output Path.join(File.cwd!(), "lib/pesque/grapheme/tables.ex")

  @sources [
    gcb: "auxiliary/GraphemeBreakProperty.txt",
    ep: "emoji/emoji-data.txt",
    incb: "DerivedCoreProperties.txt"
  ]

  @impl Mix.Task
  def run(argv) do
    dir = List.first(argv)

    if length(argv) > 1 do
      Mix.shell().info("ignoring extra arguments: #{Enum.drop(argv, 1) |> inspect()}")
    end

    gcb = read(dir, @sources[:gcb])
    ep = read(dir, @sources[:ep])
    incb = read(dir, @sources[:incb])

    tables = [
      gcb: parse_gcb(gcb),
      extended_pictographic: parse_extended_pictographic(ep),
      incb: parse_incb(incb)
    ]

    File.mkdir_p!(Path.dirname(@output))
    File.write!(@output, render(tables))

    Mix.shell().info("wrote #{@output} from Unicode #{@version}")

    for {name, ranges} <- tables do
      Mix.shell().info("  #{name}: #{length(ranges)} ranges")
    end
  end

  defp read(nil, relative) do
    {:ok, _} = Application.ensure_all_started(:inets)
    url = "https://www.unicode.org/Public/#{@version}/ucd/#{relative}"
    {:ok, {{_, 200, _}, _headers, body}} = :httpc.request(:get, {~c"#{url}", []}, [], [])
    body
  end

  defp read(dir, relative) do
    path = Path.join(dir, relative)

    case File.read(path) do
      {:ok, contents} -> contents
      {:error, reason} -> Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  # Every line of GraphemeBreakProperty.txt assigns a Grapheme_Cluster_Break
  # value, so the second field is the value.
  defp parse_gcb(contents) do
    contents
    |> lines()
    |> Enum.flat_map(fn
      [codepoints, value] -> [{range(codepoints), atom(value)}]
      _other -> []
    end)
    |> coalesce()
  end

  # emoji-data.txt assigns one property per line, named in the second field.
  defp parse_extended_pictographic(contents) do
    contents
    |> lines()
    |> Enum.flat_map(fn
      [codepoints, "Extended_Pictographic"] -> [{range(codepoints), true}]
      _other -> []
    end)
    |> coalesce()
  end

  # DerivedCoreProperties.txt assigns InCB among many other properties, which
  # is why the value sits in the third field.
  defp parse_incb(contents) do
    contents
    |> lines()
    |> Enum.flat_map(fn
      [codepoints, "InCB", value] -> [{range(codepoints), atom(value)}]
      _other -> []
    end)
    |> coalesce()
  end

  # Drops the trailing comment and splits the remaining fields on ";" without
  # carrying empty fields, which the UCD pads its columns with.
  defp lines(contents) do
    for line <- String.split(contents, "\n"),
        fields =
          line
          |> String.split("#", parts: 2)
          |> hd()
          |> String.split(";")
          |> Enum.map(&String.trim/1),
        fields != [""] do
      fields
    end
  end

  # `0000..0009` and `0000` both denote a range.
  defp range(codepoints) do
    case String.split(codepoints, "..") do
      [one] -> {String.to_integer(one, 16), String.to_integer(one, 16)}
      [lo, hi] -> {String.to_integer(lo, 16), String.to_integer(hi, 16)}
    end
  end

  # Sorts and fuses ranges that are adjacent and carry the same value, which
  # keeps the tables small without changing what they mean.
  defp coalesce(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn {{lo, hi}, value}, acc ->
      case acc do
        [{plo, phi, pvalue} | rest] when value == pvalue and lo == phi + 1 ->
          [{plo, hi, pvalue} | rest]

        _ ->
          [{lo, hi, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # The UCD spells values in CamelCase; atoms are snake_case.
  defp atom(value) do
    case value do
      "SpacingMark" -> :spacing_mark
      "Regional_Indicator" -> :regional_indicator
      "Consonant" -> :consonant
      "Linker" -> :linker
      "Other" -> :other
      "None" -> :none
      value -> value |> String.downcase() |> String.to_existing_atom()
    end
  end

  defp render(tables) do
    """
    # Generated by `mix pesque.gen_unicode`. Do not edit by hand.
    #
    # Unicode #{@version}

    defmodule Pesque.Grapheme.Tables do
      @moduledoc \"\"\"
      Unicode #{@version} character properties as sorted `{lo, hi, value}` tuples,
      one table per property. Committed so `Pesque.Grapheme` never needs the
      UCD at runtime.

      Each table is a tuple rather than a list so that `elem/2` gives O(1)
      indexed access, which is what lets the lookups below binary search
      instead of walking the ranges.
      \"\"\"

      @gcb List.to_tuple([
    #{rows(tables[:gcb])}])

      @extended_pictographic List.to_tuple([
    #{rows(tables[:extended_pictographic])}])

      @incb List.to_tuple([
    #{rows(tables[:incb])}])

      @doc "Grapheme_Cluster_Break of `cp`, `#{:other}` when the UCD lists none."
      def gcb(cp), do: lookup(@gcb, 0, tuple_size(@gcb) - 1, cp, :other)

      @doc "Whether `cp` is Extended_Pictographic. Only GB11 needs this."
      def extended_pictographic?(cp) do
        lookup(@extended_pictographic, 0, tuple_size(@extended_pictographic) - 1, cp, false)
      end

      @doc "Indic_Conjunct_Break of `cp`, `#{:none}` when the UCD lists none."
      def incb(cp), do: lookup(@incb, 0, tuple_size(@incb) - 1, cp, :none)

      defp lookup(_table, lo, hi, _cp, default) when lo > hi, do: default

      defp lookup(table, lo, hi, cp, default) do
        mid = div(lo + hi, 2)
        {range_lo, range_hi, value} = elem(table, mid)

        cond do
          cp < range_lo -> lookup(table, lo, mid - 1, cp, default)
          cp > range_hi -> lookup(table, mid + 1, hi, cp, default)
          true -> value
        end
      end
    end
    """
  end

  defp rows(ranges) do
    Enum.map_join(ranges, "\n", fn {lo, hi, value} ->
      "        {#{hex(lo)}, #{hex(hi)}, #{inspect(value)}},"
    end)
  end

  defp hex(n), do: "0x#{n |> Integer.to_string(16) |> String.upcase()}"
end
