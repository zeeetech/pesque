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

  test "a record may reach but not exceed the CBOR size limit" do
    limit = Commit.max_record_bytes()
    {text_size, change} = change_with_data_size("boundary", limit)

    assert byte_size(change.data) == limit
    assert {:error, :record_too_large} = write_result("boundary", text_size + 1)
  end

  test "individually valid records cannot produce an oversized commit CAR" do
    changes =
      for n <- 1..3 do
        {_text_size, change} = change_with_data_size("car#{n}", 900_000)
        change
      end

    assert {:ok, prepared} = Commit.commit(state(%{}), changes)
    assert {:error, :commit_too_large} = Commit.frame(prepared, 1, changes)
  end

  test "a frame cannot exceed the operation limit" do
    changes = for n <- 1..201, do: change("com.example.record/#{n}", n)

    assert {:ok, prepared} = Commit.commit(state(%{}), changes)
    assert {:error, :too_many_ops} = Commit.frame(prepared, 1, changes)
  end

  test "the encoded frame has a defensive size limit" do
    assert {:ok, prepared} = Commit.commit(state(%{}), [])
    prepared = %{prepared | did: String.duplicate("d", Commit.max_frame_bytes())}

    assert {:error, :frame_too_large} = Commit.frame(prepared, 1, [])
  end

  defp change_with_data_size(key, target) do
    {:ok, empty} = write_result(key, 0)
    adjust_write(key, target, target - byte_size(empty.data) - 16)
  end

  defp adjust_write(key, target, text_size) do
    {:ok, change} = write_result(key, text_size)

    case target - byte_size(change.data) do
      0 -> {text_size, change}
      delta -> adjust_write(key, target, text_size + delta)
    end
  end

  defp write_result(key, text_size) do
    record = %{
      "$type" => "app.bsky.feed.post",
      "key" => key,
      "text" => String.duplicate("x", text_size),
      "createdAt" => "2024-01-01T00:00:00.000Z"
    }

    Commit.encode_write(%{}, :create, "app.bsky.feed.post/" <> key, record)
  end
end
