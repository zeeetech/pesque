defmodule Pesque.Mst do
  @moduledoc """
  Canonical Merkle Search Tree construction.

  build/1 takes the full %{key => %CID{}} entry map and produces the root
  CID plus all node blocks. The output is byte-identical to what the
  reference TypeScript implementation produces through incremental
  adds, deletes, and updates, because the tree is a deterministic
  function of the entry set:

    * key depth = leading zero bits of sha256(key), counted in 2-bit
      chunks (a zero byte counts 4, then continue)
    * a node at layer L holds the keys with depth == L in its range,
      sorted, with prefix compression against the previous key
    * subtrees hang between entries and always sit exactly one layer
      down; empty filler nodes bridge any gap
  """

  alias Pesque.CBOR
  alias Pesque.CID

  @doc "Key depth: count of leading zero bits of sha256(key), divided by 2."
  def depth(key) when is_binary(key) do
    do_depth(:crypto.hash(:sha256, key), 0)
  end

  defp do_depth(<<>>, acc), do: acc
  defp do_depth(<<0, rest::binary>>, acc), do: do_depth(rest, acc + 4)
  defp do_depth(<<b, _rest::binary>>, acc) when b < 4, do: acc + 3
  defp do_depth(<<b, _rest::binary>>, acc) when b < 16, do: acc + 2
  defp do_depth(<<b, _rest::binary>>, acc) when b < 64, do: acc + 1
  defp do_depth(<<_b, _rest::binary>>, acc), do: acc

  @doc "Returns {root_cid, blocks} where blocks maps %CID{} -> encoded node bytes."
  def build(entries) when is_map(entries) do
    case Enum.sort(Map.to_list(entries)) do
      [] ->
        add_block({nil, []}, %{})

      sorted ->
        layer = sorted |> Enum.map(fn {k, _v} -> depth(k) end) |> Enum.max()
        node_for(sorted, layer, %{})
    end
  end

  # Builds one node for entries whose depths are all <= layer, adds its
  # block, and returns {cid, blocks}.
  defp node_for(entries, layer, blocks) do
    {left, rest} = Enum.split_while(entries, fn {k, _v} -> depth(k) < layer end)

    {l, blocks} =
      case left do
        [] -> {nil, blocks}
        _ -> node_for(left, layer - 1, blocks)
      end

    {es, blocks} = collect(rest, layer, [], blocks)
    add_block({l, es}, blocks)
  end

  # Walks entries at this layer: keys with depth == layer become entries,
  # runs of deeper keys between them become right subtrees.
  defp collect([], _layer, acc, blocks), do: {Enum.reverse(acc), blocks}

  defp collect([{k, v} | rest], layer, acc, blocks) do
    if depth(k) != layer do
      raise ArgumentError, "MST build invariant violated: key depth above node layer"
    end

    {group, rest2} = Enum.split_while(rest, fn {k2, _v2} -> depth(k2) < layer end)

    {t, blocks} =
      case group do
        [] -> {nil, blocks}
        _ -> node_for(group, layer - 1, blocks)
      end

    collect(rest2, layer, [{k, v, t} | acc], blocks)
  end

  defp add_block(node, blocks) do
    bytes = CBOR.encode(serialize(node))
    cid = CID.from_data(bytes)
    {cid, Map.put(blocks, cid, bytes)}
  end

  defp serialize({l, es}) do
    {entries, _last} =
      Enum.map_reduce(es, "", fn {k, v, t}, prev ->
        p = common_prefix(prev, k)
        suffix = binary_part(k, p, byte_size(k) - p)

        {%{"k" => %CBOR.Bytes{data: suffix}, "p" => p, "t" => t, "v" => v}, k}
      end)

    %{"e" => entries, "l" => l}
  end

  defp common_prefix(a, b), do: common_prefix(a, b, 0)
  defp common_prefix(<<c, ar::binary>>, <<c, br::binary>>, n), do: common_prefix(ar, br, n + 1)
  defp common_prefix(_a, _b, n), do: n
end
