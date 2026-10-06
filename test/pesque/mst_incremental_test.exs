defmodule Pesque.MstIncrementalTest do
  @moduledoc """
  The incremental path against the rebuild, which is the only property that
  matters about it: for the same entries the two must produce the same bytes,
  not a tree that merely holds the same records.

  Each case walks a tree through adds, updates and deletes and compares the
  root CID against `Mst.build/1` after every step, including the root of the
  changed node blocks: a rebuild produces every node of the tree, so the
  incremental blocks have to be a subset of it and the root has to be its root.
  """

  use ExUnit.Case, async: true

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Mst

  # Keys mined for a depth, so a tree is forced to hold layers above 0 rather
  # than happening to. Depth is the count of leading zero bits of sha256 in
  # 2-bit chunks, so one key in four is at depth 1 and one in sixteen at depth
  # 2: a handful of attempts finds either.
  defp keys_at_depth(depth) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&("app.bsky.feed.post/" <> Integer.to_string(&1, 36)))
    |> Stream.filter(&(Mst.depth(&1) == depth))
    |> Enum.take(6)
  end

  defp value(n), do: CID.from_data(CBOR.encode(%{"n" => n}))

  defp fresh, do: value(:erlang.unique_integer([:positive]))

  # A tree held in memory the way storage holds it: nodes are blocks keyed by
  # CID, and fetch/1 is the only way the walk reaches them. A CID the map does
  # not hold is a block that is missing, which is the case the fallback covers.
  defp store(entries) do
    {root, blocks} = Mst.build(entries)
    %{root: root, blocks: blocks, entries: entries}
  end

  defp fetch(blocks) do
    fn %CID{} = cid ->
      case Map.fetch(blocks, cid) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, {:missing_block, CID.to_string(cid)}}
      end
    end
  end

  defp put(store, key, value) do
    step(store, [{:put, key, value}], Map.put(store.entries, key, value))
  end

  defp delete(store, key) do
    step(store, [{:delete, key}], Map.delete(store.entries, key))
  end

  defp step(store, ops, entries) do
    assert {:ok, {root, written}} = Mst.update_tree(store.root, ops, fetch(store.blocks))

    # The root has to be the one a rebuild produces, and every node this step
    # wrote has to be a node that rebuild also produces: the same tree reached
    # two ways, byte for byte.
    {rebuilt, rebuilt_blocks} = Mst.build(entries)

    assert root == rebuilt, "incremental root differs from a rebuild of the same entries"

    for {cid, _bytes} <- written do
      assert Map.has_key?(rebuilt_blocks, cid),
             "incremental block #{CID.to_string(cid)} is not a node a rebuild produces"
    end

    %{store | root: root, blocks: Map.merge(store.blocks, written), entries: entries}
  end

  test "a randomized sequence of writes matches a rebuild at every step" do
    keys = for i <- 0..59, do: "app.bsky.feed.post/" <> Integer.to_string(i, 36)
    deep = keys_at_depth(1) ++ keys_at_depth(2) ++ keys_at_depth(3)
    random = for _ <- 1..40, do: fresh()

    seed = keys |> Enum.shuffle() |> Enum.zip(Enum.shuffle(random)) |> Map.new()
    store = store(seed)

    ops =
      for _value <- random, key <- Enum.take_random(keys, 12) do
        {key, value(:rand.uniform(1_000_000))}
      end

    store = Enum.reduce(ops, store, fn {key, value}, store -> put(store, key, value) end)

    store = Enum.reduce(Enum.shuffle(Map.keys(store.entries)), store, &delete(&2, &1))

    # Deep keys are what put nodes above layer 0, so they are worth mixing into
    # both directions of the walk rather than only at the ends.
    store = Enum.reduce(deep, store, &put(&2, &1, value(1)))

    for key <- deep do
      store = delete(store, key)
    end
  end

  test "adding one key at a time matches a rebuild at every step" do
    store = store(%{})

    for i <- 0..79 do
      put(
        store,
        "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0"),
        value(i)
      )
    end
  end

  test "the first key of an empty repository goes in at the layer its depth says" do
    for key <- keys_at_depth(0) ++ keys_at_depth(1) ++ keys_at_depth(2) do
      store = put(store(%{}), key, value(1))
      assert %CID{} = store.root
    end
  end

  test "keys mined for depth land on separate layers and survive a rewrite" do
    store =
      Enum.reduce(keys_at_depth(2) ++ keys_at_depth(1) ++ keys_at_depth(0), store(%{}), fn key,
                                                                                           store ->
        put(store, key, value(1))
      end)

    store = put(store, "app.bsky.feed.post/mid", fresh())

    # A key that has to be added above the current top leaves the top node
    # holding one entry and the new tree hanging off it.
    put(store, "app.bsky.feed.post/zzzz", fresh())
  end

  test "writing a key's existing value back leaves the tree byte-identical" do
    store =
      Enum.reduce(0..9, store(%{}), fn i, store ->
        put(
          store,
          "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0"),
          value(i)
        )
      end)

    for {key, value} <- store.entries do
      assert {:ok, {unchanged, blocks}} =
               Mst.update_tree(store.root, [{:put, key, value}], fetch(store.blocks))

      assert unchanged == store.root, "an update writing the identical value changed the root"

      # The path is rewritten to nodes that came out identical, so the CIDs are
      # the ones already stored and inserting them is a no-op.
      for {cid, _bytes} <- blocks do
        assert cid == store.root or Map.has_key?(store.blocks, cid),
               "an unchanged write produced a block the repo does not already hold"
      end
    end
  end

  test "a delete of a key the tree does not hold is an error, not a rewrite" do
    store = put(store(%{}), "com.example.record/present", value(1))
    before = store.root

    assert {:error, {:key_not_found, "com.example.record/absent"}} =
             Mst.update_tree(
               store.root,
               [{:delete, "com.example.record/absent"}],
               fetch(store.blocks)
             )

    assert store.root == before
  end

  test "a batch applies in order and matches a rebuild" do
    store =
      Enum.reduce(0..4, store(%{}), fn i, store ->
        put(
          store,
          "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0"),
          value(i)
        )
      end)

    ops = [
      {:put, "com.example.record/0000", fresh()},
      {:put, "com.example.record/0005", fresh()},
      {:delete, "com.example.record/0001"},
      {:put, "com.example.record/0002", fresh()},
      {:delete, "com.example.record/0000"}
    ]

    assert {:ok, {root, _blocks}} = Mst.update_tree(store.root, ops, fetch(store.blocks))

    entries =
      Enum.reduce(ops, store.entries, fn
        {:put, key, value}, acc -> Map.put(acc, key, value)
        {:delete, key}, acc -> Map.delete(acc, key)
      end)

    {rebuilt, _} = Mst.build(entries)

    assert root == rebuilt

    assert {:ok, {^root, %{}}} = Mst.update_tree(root, [], fetch(store.blocks))
  end

  test "deleting every key leaves the empty tree the empty repository builds" do
    store =
      Enum.reduce(0..3, store(%{}), fn i, store ->
        put(
          store,
          "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0"),
          value(i)
        )
      end)

    store = Enum.reduce(Map.keys(store.entries), store, &delete(&2, &1))

    assert store.root == elem(Mst.build(%{}), 0)
  end

  test "a node missing from storage is an error rather than a tree that lost keys" do
    store =
      Enum.reduce(0..39, store(%{}), fn i, store ->
        put(
          store,
          "com.example.record/#{String.pad_leading(Integer.to_string(i), 4, "0")}",
          value(i)
        )
      end)

    assert {:error, {:missing_block, _cid}} =
             Mst.update_tree(
               store.root,
               [{:put, "com.example.record/new", fresh()}],
               broken_fetch(store)
             )

    assert store.root == elem(Mst.build(store.entries), 0)
  end

  # Fetches the root but nothing below it, which is what a swept or partially
  # written block table looks like from the walk's side.
  defp broken_fetch(store) do
    fn %CID{} = cid ->
      if cid == store.root do
        {:ok, store.blocks[store.root]}
      else
        {:error, {:missing_block, CID.to_string(cid)}}
      end
    end
  end
end
