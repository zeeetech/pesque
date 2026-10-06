defmodule Pesque.CommitTest do
  @moduledoc """
  The commit path picks the MST route, and it says which one it took. A
  rebuild is legal but has to be visible, so these tests pin the choice
  rather than only the bytes it produces.
  """

  use ExUnit.Case, async: true

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Commit
  alias Pesque.Mst

  @did "did:web:pds.example.com:user:alice"

  defp value(n), do: CID.from_data(CBOR.encode(%{"n" => n}))

  defp change(key, n),
    do: %{action: "create", key: key, cid: value(n), data: CBOR.encode(%{"n" => n})}

  defp state(entries) do
    {root, blocks} = Mst.build(entries)
    {_pub, priv} = Pesque.Secp256k1.generate_keypair()

    %{
      did: @did,
      clock_id: 1,
      priv: priv,
      entries: entries,
      rev: nil,
      tid_int: 0,
      commit_cid: nil,
      root_cid: root,
      fetch: fn cid ->
        case Map.fetch(blocks, cid) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, {:missing_block, CID.to_string(cid)}}
        end
      end
    }
  end

  test "a write against a stored tree updates it incrementally" do
    state = state(%{"com.example.record/a" => value(1)})

    assert {:ok, prepared} = Commit.commit(state, [change("com.example.record/b", 2)])

    assert prepared.mst == :incremental
    assert {root, _} = Mst.build(prepared.entries)
    assert root == prepared.root_cid
  end

  test "an unwalkable tree falls back to a rebuild and says so" do
    state = state(%{"com.example.record/a" => value(1)})

    broken = %{state | fetch: fn _cid -> {:error, {:missing_block, "gone"}} end}

    assert {:ok, prepared} = Commit.commit(broken, [change("com.example.record/b", 2)])

    assert {:rebuild, {:missing_block, _}} = prepared.mst
    assert {root, _} = Mst.build(prepared.entries)
    assert root == prepared.root_cid
  end

  test "the genesis commit builds the tree" do
    state = %{state(%{}) | root_cid: nil}

    assert {:ok, prepared} = Commit.commit(state, [change("com.example.record/a", 1)])

    assert prepared.mst == :genesis
    assert {root, _} = Mst.build(prepared.entries)
    assert root == prepared.root_cid
  end
end
