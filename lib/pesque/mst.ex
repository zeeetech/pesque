defmodule Pesque.Mst do
  @moduledoc """
  Canonical Merkle Search Tree construction.

  The tree is a deterministic function of the entry set, and both paths
  here produce the same one:

    * key depth = leading zero bits of sha256(key), counted in 2-bit
      chunks (a zero byte counts 4, then continue)
    * a node at layer L holds the keys with depth == L in its range,
      sorted, with prefix compression against the previous key
    * subtrees hang between entries and always sit exactly one layer
      down; empty filler nodes bridge any gap

  build/1 takes the whole `%{key => %CID{}}` entry map and produces the root
  plus every node block. It is the genesis path, and it is the repair path:
  a tree that cannot be walked is rebuilt from the entry map rather than
  served broken.

  update_tree/3 takes the tree as it is stored, the root CID, and a fetch
  function, and applies a list of puts and deletes to it in order. Only the
  nodes a change rewrites are read and returned, so a write costs the depth
  of the tree rather than the size of the repo. The bytes it produces are
  the same bytes a rebuild of the resulting entry map would produce.
  """

  alias Pesque.CBOR
  alias Pesque.CID

  defmodule Node do
    @moduledoc """
    One MST node, in the shape the layering rules need.

    `entries` is a flat key-sorted list alternating leaves and subtrees, the
    shape the reference implementation mutates. A nil `entries` means the
    node has not been read yet; `cid` is then all that is known of it, which
    is all a node nobody touched needs. A node this module rewrote is
    `dirty`, and dirty is what makes flush/2 write a block for it.
    """
    defstruct [:cid, :layer, entries: nil, dirty: false]
  end

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
    sorted =
      entries
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {k, v, depth(k)} end)
      |> Enum.sort_by(fn {k, _v, _d} -> k end)

    case sorted do
      [] ->
        add_block({nil, []}, %{})

      _ ->
        layer = sorted |> Enum.map(fn {_k, _v, d} -> d end) |> Enum.max()
        node_for(sorted, layer, %{})
    end
  end

  # Builds one node for entries whose depths are all <= layer, adds its
  # block, and returns {cid, blocks}.
  defp node_for(entries, layer, blocks) do
    {left, rest} = Enum.split_while(entries, fn {_k, _v, d} -> d < layer end)

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

  defp collect([{k, v, d} | rest], layer, acc, blocks) do
    if d != layer do
      raise ArgumentError, "MST build invariant violated: key depth above node layer"
    end

    {group, rest2} = Enum.split_while(rest, fn {_k2, _v2, d2} -> d2 < layer end)

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

  # Incremental updates
  # ------------------
  #
  # These are the reference implementation's operations, in the same order and
  # against the same invariants. An add either lands in the node it was aimed
  # at, drops into the subtree the key belongs to, or pushes that whole subtree
  # down a layer; a delete either removes a leaf or merges the subtrees that
  # end up neighbouring. Following the reference's rules is what makes the
  # bytes this produces identical to the bytes a rebuild of the resulting entry
  # map produces.

  @doc """
  Applies `ops` to the tree stored under `root_cid`, answering the new root and
  the node blocks that changed.

  `ops` is applied in order. Each is `{:put, key, value}` (an add when the key
  is absent, an update when it is there), `{:update, key, value}` or
  `{:delete, key}`.

  `fetch` is given a `%CID{}` and answers `{:ok, bytes}` or `{:error, reason}`.
  Only the nodes on the path a change rewrites are read, and only the nodes
  that changed come back in the block map: a subtree nobody touched keeps the
  CID its parent already points at, and its block is already stored.

  A node that is missing or does not decode answers `{:error, reason}`, as does
  a delete of a key the tree does not hold. Neither is repaired here, because
  neither is something this module can answer honestly: the caller decides
  what an unreadable tree means, and rebuilding it from the entry map is the
  answer that serves a correct tree.
  """
  def update_tree(root_cid, ops, fetch) when is_function(fetch, 1) do
    with {:ok, node} <- Enum.reduce_while(ops, {:ok, %Node{cid: root_cid}}, &apply_op(&1, &2, fetch)) do
      {root, blocks} = flush(node, %{})
      {:ok, {root, blocks}}
    end
  end

  defp apply_op(op, {:ok, node}, fetch) do
    case change(op, node, fetch) do
      {:ok, node} -> {:cont, {:ok, node}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp change({:put, key, value}, node, fetch) do
    case get(key, node, fetch) do
      {:ok, nil} -> add(key, value, node, fetch)
      {:ok, %CID{}} -> update(key, value, node, fetch)
      {:error, _reason} = error -> error
    end
  end

  defp change({:update, key, value}, node, fetch), do: update(key, value, node, fetch)
  defp change({:delete, key}, node, fetch), do: delete(key, node, fetch)

  defp get(key, node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)

      case at(node.entries, index) do
        {:leaf, ^key, value} ->
          {:ok, value}

        _absent ->
          descend(key, node, index, fetch, &get/3)
      end
    end
  end

  # A node's layer is not stored with it: it is the depth of the first leaf the
  # node holds, and a node holding no leaf of its own takes it from the first
  # subtree below it. A node with neither is layer 0.
  defp layer(%Node{layer: layer} = node, _fetch) when is_integer(layer), do: {:ok, node}

  defp layer(node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      case layer_of(node, fetch) do
        {:ok, layer} -> {:ok, %Node{node | layer: layer}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp layer_of(%Node{layer: layer}, _fetch) when is_integer(layer), do: {:ok, layer}

  defp layer_of(node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      case Enum.find(node.entries, &leaf?/1) do
        {:leaf, key, _value} -> {:ok, depth(key)}
        nil -> layer_below(node, fetch)
      end
    end
  end

  defp layer_below(node, fetch) do
    Enum.reduce_while(node.entries, {:ok, 0}, fn
      {:node, child}, acc ->
        case entries(child, fetch) do
          {:ok, %Node{entries: []}} ->
            {:cont, acc}

          {:ok, child} ->
            case layer_of(child, fetch) do
              {:ok, layer} -> {:halt, {:ok, layer + 1}}
              {:error, _reason} = error -> {:halt, error}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end

      _leaf, acc ->
        {:cont, acc}
    end)
  end

  # entries/2 answers the node with its entries filled in, loading them from
  # storage the first time they are asked for. A node whose entries are already
  # known costs nothing to ask again, which is what makes the walk below a walk
  # over memory once it is under way.
  defp entries(%Node{entries: entries} = node, _fetch) when is_list(entries), do: {:ok, node}

  defp entries(%Node{cid: cid} = node, fetch) do
    case fetch.(cid) do
      {:ok, bytes} ->
        case decode_node(bytes) do
          {:ok, entries} -> {:ok, %Node{node | entries: entries}}
          :error -> {:error, {:corrupt_node, cid}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A node stores each key as the bytes it shares with the key before it plus
  # its own remainder, so the key a write is aimed at only exists once the node
  # has been read.
  defp decode_node(bytes) do
    %{"l" => left, "e" => encoded} = CBOR.decode!(bytes)
    leading = if left, do: [{:node, %Node{cid: left}}], else: []
    {:ok, leading ++ decode_entries(encoded, "")}
  rescue
    _ -> :error
  end

  defp decode_entries(encoded, last) do
    {reversed, _last} =
      Enum.reduce(encoded, {[], last}, fn
        %{"k" => %CBOR.Bytes{data: suffix}, "p" => shared, "v" => value, "t" => tree},
        {acc, last} ->
          key = binary_part(last, 0, min(shared, byte_size(last))) <> suffix
          acc = [{:leaf, key, value} | acc]
          acc = if tree, do: [{:node, %Node{cid: tree}} | acc], else: acc
          {acc, key}
      end)

    Enum.reverse(reversed)
  rescue
    _ -> raise(ArgumentError, "malformed MST node entry")
  end

  defp add(key, value, node, fetch, known_zeros \\ nil) do
    zeros = known_zeros || depth(key)

    with {:ok, node} <- layer(node, fetch) do
      cond do
        zeros == node.layer -> add_here(key, value, node, fetch)
        zeros < node.layer -> add_below(key, value, node, zeros, fetch)
        true -> add_above(key, value, node, zeros, fetch)
      end
    end
  end

  defp add_here(key, value, node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)

      case at(node.entries, index) do
        {:leaf, ^key, _value} ->
          {:error, {:key_exists, key}}

        _absent ->
          insert(key, value, node, index, fetch)
      end
    end
  end

  # The key belongs to this layer, so it becomes a leaf here. The only case
  # worth more than a splice is the one where the entry before it is a subtree:
  # the key falls inside that subtree's range, so the subtree splits around the
  # key and the key lands between the halves.
  defp insert(key, value, node, index, fetch) do
    case at(node.entries, index - 1) do
      {:node, previous} ->
        with {:ok, {left, right}} <- split_around(key, previous, fetch) do
          entries =
            Enum.take(node.entries, index - 1) ++
              Enum.reject([wrap(left), {:leaf, key, value}, wrap(right)], &is_nil/1) ++
              Enum.drop(node.entries, index)

          {:ok, new_tree(node, entries)}
        end

      _leaf_or_nil ->
        {:ok, new_tree(node, List.insert_at(node.entries, index, {:leaf, key, value}))}
    end
  end

  # The key belongs to a layer below this one. If the entry before where it
  # sorts is already a subtree, the key drops into it; if it is a leaf or this
  # is the far left, a subtree is created there to hold it.
  defp add_below(key, value, node, zeros, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)

      case at(node.entries, index - 1) do
        {:node, child} ->
          with {:ok, child} <- add(key, value, child, fetch, zeros) do
            {:ok, new_tree(node, replace(node.entries, index - 1, {:node, child}))}
          end

        _leaf_or_nil ->
          with {:ok, child} <- create_child(node, fetch),
               {:ok, child} <- add(key, value, child, fetch, zeros) do
            {:ok, new_tree(node, List.insert_at(node.entries, index, {:node, child}))}
          end
      end
    end
  end

  # The key belongs to a layer above this one, so it becomes the root of a new
  # tree with everything that was here split around it. A key more than one
  # layer up needs empty parents between it and the halves, or the subtree
  # links would skip a level.
  defp add_above(key, value, node, zeros, fetch) do
    with {:ok, {left, right}} <- split_around(key, node, fetch) do
      {left, right} = push_down(left, right, zeros - node.layer - 1, fetch)

      entries = Enum.reject([wrap(left), {:leaf, key, value}, wrap(right)], &is_nil/1)
      {:ok, %Node{entries: entries, layer: zeros, dirty: true}}
    end
  end

  defp push_down(left, right, 0, _fetch), do: {left, right}

  defp push_down(left, right, levels, fetch) do
    {:ok, left} = if left, do: create_parent(left, fetch), else: {:ok, nil}
    {:ok, right} = if right, do: create_parent(right, fetch), else: {:ok, nil}
    push_down(left, right, levels - 1, fetch)
  end

  defp update(key, value, node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)

      case at(node.entries, index) do
        {:leaf, ^key, _value} ->
          {:ok, new_tree(node, replace(node.entries, index, {:leaf, key, value}))}

        _absent ->
          case at(node.entries, index - 1) do
            {:node, child} ->
              with {:ok, child} <- update(key, value, child, fetch) do
                {:ok, new_tree(node, replace(node.entries, index - 1, {:node, child}))}
              end

            _leaf_or_nil ->
              {:error, {:key_not_found, key}}
          end
      end
    end
  end

  defp delete(key, node, fetch) do
    with {:ok, node} <- delete_recurse(key, node, fetch), do: trim_top(node, fetch)
  end

  defp delete_recurse(key, node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)

      case at(node.entries, index) do
        {:leaf, ^key, _value} ->
          drop_leaf(node, index, fetch)

        _absent ->
          case at(node.entries, index - 1) do
            {:node, child} ->
              with {:ok, child} <- delete_recurse(key, child, fetch) do
                if child.entries == [] do
                  {:ok, new_tree(node, List.delete_at(node.entries, index - 1))}
                else
                  {:ok, new_tree(node, replace(node.entries, index - 1, {:node, child}))}
                end
              end

            _leaf_or_nil ->
              {:error, {:key_not_found, key}}
          end
      end
    end
  end

  # Removing a leaf that had a subtree on both sides would leave two subtrees
  # neighbouring, which is a shape no node may have, so they merge into one.
  defp drop_leaf(node, index, fetch) do
    case {at(node.entries, index - 1), at(node.entries, index + 1)} do
      {{:node, left}, {:node, right}} ->
        with {:ok, merged} <- append_merge(left, right, fetch) do
          entries =
            Enum.take(node.entries, index - 1) ++ [{:node, merged}] ++
              Enum.drop(node.entries, index + 2)

          {:ok, new_tree(node, entries)}
        end

      _one_sided ->
        {:ok, new_tree(node, List.delete_at(node.entries, index))}
    end
  end

  # A tree must not be a node that only points at another node. The top carries
  # the layer, and a chain of nodes that only point down would report keys at a
  # layer they do not belong to.
  defp trim_top(node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      case node.entries do
        [{:node, child}] ->
          with {:ok, child} <- entries(child, fetch), do: trim_top(child, fetch)

        _top ->
          {:ok, node}
      end
    end
  end

  # Every key on the left sorts before every key on the right and the two are
  # at the same layer, so their entries concatenate unless the last entry of one
  # and the first of the other are both subtrees, in which case those two
  # neighbours merge instead.
  defp append_merge(left, right, fetch) do
    with {:ok, left} <- layer(left, fetch),
         {:ok, right} <- layer(right, fetch) do
      if left.layer == right.layer do
        merge_entries(left, right, fetch)
      else
        {:error, :layer_mismatch}
      end
    end
  end

  defp merge_entries(left, right, fetch) do
    with {:ok, left} <- entries(left, fetch),
         {:ok, right} <- entries(right, fetch) do
      case {List.last(left.entries), List.first(right.entries)} do
        {{:node, left_last}, {:node, right_first}} ->
          with {:ok, merged} <- append_merge(left_last, right_first, fetch) do
            entries =
              Enum.drop(left.entries, -1) ++ [{:node, merged}] ++ Enum.drop(right.entries, 1)

            {:ok, new_tree(left, entries)}
          end

        _not_adjacent ->
          {:ok, new_tree(left, left.entries ++ right.entries)}
      end
    end
  end

  # Splits a node around `key`: everything sorting below it, everything sorting
  # above it, and, when the key falls inside the range of the last subtree on
  # the lower side rather than beside it, that subtree splits too. An empty side
  # comes back as nil rather than as an empty node, because a node with no
  # entries is only legal as the root of an empty repository.
  defp split_around(key, node, fetch) do
    with {:ok, node} <- entries(node, fetch) do
      index = find_gte(node.entries, key)
      lower = Enum.take(node.entries, index)
      upper = Enum.drop(node.entries, index)

      case List.last(lower) do
        {:node, last} ->
          with {:ok, {left, right}} <- split_around(key, last, fetch) do
            base = Enum.drop(lower, -1)

            left =
              if left, do: new_tree(node, base ++ [{:node, left}]), else: new_tree(node, base)

            right =
              if right, do: new_tree(node, [{:node, right} | upper]), else: new_tree(node, upper)

            {:ok, {nonempty(left), nonempty(right)}}
          end

        _leaf_or_nil ->
          {:ok, {new_tree(node, lower) |> nonempty(), new_tree(node, upper) |> nonempty()}}
      end
    end
  end

  defp nonempty(%Node{entries: []}), do: nil
  defp nonempty(node), do: node

  defp wrap(nil), do: nil
  defp wrap(node), do: {:node, node}

  defp descend(key, node, index, fetch, fun) do
    case at(node.entries, index - 1) do
      {:node, child} ->
        with {:ok, child} <- entries(child, fetch), do: fun.(key, child, fetch)

      _leaf_or_nil ->
        {:ok, nil}
    end
  end

  defp create_child(node, fetch) do
    with {:ok, node} <- layer(node, fetch) do
      {:ok, %Node{entries: [], layer: node.layer - 1, dirty: true}}
    end
  end

  defp create_parent(node, fetch) do
    with {:ok, node} <- layer(node, fetch) do
      {:ok, %Node{entries: [{:node, node}], layer: node.layer + 1, dirty: true}}
    end
  end

  defp new_tree(%Node{} = node, entries), do: %Node{node | entries: entries, dirty: true}

  defp replace(entries, index, entry), do: List.replace_at(entries, index, entry)

  # The index of the first leaf at or after `key`, or the end of the node when
  # every leaf sorts before it. Subtrees are not candidates: what the index is
  # for is a position in the flat list, and only leaves can be it.
  defp find_gte(entries, key), do: find_gte(entries, key, 0)

  defp find_gte([], _key, index), do: index
  defp find_gte([{:leaf, k, _value} | _rest], key, index) when k >= key, do: index
  defp find_gte([_entry | rest], key, index), do: find_gte(rest, key, index + 1)

  defp at(_entries, index) when index < 0, do: nil
  defp at(entries, index), do: Enum.at(entries, index)

  defp leaf?({:leaf, _key, _value}), do: true
  defp leaf?(_entry), do: false

  # A node nobody rewrote keeps the CID it was read under: its block is already
  # stored and the parent naming it is already correct. A node this walk
  # rewrote is serialized bottom up, so each child resolves to the CID its
  # parent is about to name, and the new block lands in the map.
  defp flush(%Node{dirty: false, cid: cid}, blocks), do: {cid, blocks}

  defp flush(%Node{entries: entries}, blocks) do
    {left, es, blocks} = resolve(entries, nil, [], blocks)
    add_block({left, es}, blocks)
  end

  defp resolve([{:node, child} | rest], _left, acc, blocks) do
    {cid, blocks} = flush(child, blocks)
    resolve(rest, cid, acc, blocks)
  end

  defp resolve([{:leaf, key, value} | rest], left, acc, blocks) do
    {tree, rest, blocks} =
      case rest do
        [{:node, child} | more] ->
          {cid, blocks} = flush(child, blocks)
          {cid, more, blocks}

        more ->
          {nil, more, blocks}
      end

    resolve(rest, left, [{key, value, tree} | acc], blocks)
  end

  defp resolve([], left, acc, blocks), do: {left, Enum.reverse(acc), blocks}
end
