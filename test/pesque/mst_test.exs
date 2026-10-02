defmodule Pesque.MstTest do
  use ExUnit.Case, async: true

  alias Pesque.{CBOR, CID, Mst}

  test "matches the root CID produced by the reference implementation" do
    entries =
      for i <- 0..9, into: %{} do
        key = "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0")
        {key, CID.from_data(CBOR.encode(%{"i" => i}))}
      end

    {root, blocks} = Mst.build(entries)

    assert CID.to_string(root) == "bafyreiauu4dlrmesbnb7i24u7niyunmpxb6bg4dmpo7ul7wnslx5b77gf4"
    assert map_size(blocks) == 4
  end

  test "depth returns an integer and is deterministic" do
    key = "com.example.record/0000"

    assert is_integer(Mst.depth(key))
    assert Mst.depth(key) == Mst.depth(key)
    assert Mst.depth("") == Mst.depth("")
  end

  test "an empty entry map produces a root and one block" do
    {root, blocks} = Mst.build(%{})

    assert %CID{} = root
    assert map_size(blocks) == 1
    assert CBOR.decode!(blocks[root]) == %{"e" => [], "l" => nil}
  end

  test "the same entry set always produces the same root" do
    {first_root, _} = Mst.build(sample())
    {second_root, _} = Mst.build(sample())

    assert first_root == second_root
  end

  test "insertion order does not matter" do
    forward = for i <- 0..5, into: %{}, do: {key(i), value(i)}
    backward = for i <- 5..0//-1, into: %{}, do: {key(i), value(i)}

    assert {forward_root, _} = Mst.build(forward)
    assert {backward_root, _} = Mst.build(backward)
    assert forward_root == backward_root
  end

  test "adding an entry changes the root" do
    entries = sample()
    {before_root, _} = Mst.build(entries)
    {after_root, _} = Mst.build(Map.put(entries, key(99), value(99)))

    assert CID.to_string(before_root) != CID.to_string(after_root)
  end

  test "removing an entry restores the previous root" do
    entries = sample()
    {base_root, _} = Mst.build(entries)
    grown = Map.put(entries, key(99), value(99))
    {grown_root, _} = Mst.build(grown)
    {rebuilt_root, _} = Mst.build(Map.delete(grown, key(99)))

    assert CID.to_string(base_root) != CID.to_string(grown_root)
    assert base_root == rebuilt_root
  end

  defp sample, do: for(i <- 0..5, into: %{}, do: {key(i), value(i)})
  defp key(i), do: "com.example.record/" <> String.pad_leading(Integer.to_string(i), 4, "0")
  defp value(i), do: CID.from_data(CBOR.encode(%{"i" => i}))
end
