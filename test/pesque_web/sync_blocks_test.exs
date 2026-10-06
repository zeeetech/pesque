defmodule PesqueWeb.SyncBlocksTest do
  @moduledoc """
  The two block endpoints: getBlocks by CID, and the sync-namespace getRecord.

  Both answer a CAR whose blocks are checked here rather than trusted, because
  what a mirror does with them is the whole point: getBlocks has to hand back
  every block it was asked for or say so, and getRecord has to hand back enough
  to place the record rather than the record alone.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.RepoStore

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  describe "getBlocks" do
    test "answers a CAR carrying every requested block", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")

      conn = get_blocks(ctx.alice.did, [cid, commit(ctx.alice.did)])

      assert conn.status == 200
      assert ["application/vnd.ipld.car" <> _] = get_resp_header(conn, "content-type")

      {roots, blocks} = Car.decode(conn.resp_body)

      assert roots == [CID.parse(commit(ctx.alice.did))]
      assert blocks[CID.parse(cid)] == block_bytes(ctx.alice.did, cid)

      assert blocks[CID.parse(commit(ctx.alice.did))] ==
               block_bytes(ctx.alice.did, commit(ctx.alice.did))
    end

    test "a CID this repo does not store answers BlockNotFound", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")
      unknown = CID.to_string(CID.from_data("a block nobody stored"))

      conn = get_blocks(ctx.alice.did, [cid, unknown])

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "BlockNotFound"
    end

    # A partial CAR would be indistinguishable from a repo that has nothing
    # else, so the whole request fails instead of quietly answering short.
    test "one missing CID fails the request rather than answering short", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")
      unknown = CID.to_string(CID.from_data("a block nobody stored"))

      conn = get_blocks(ctx.alice.did, [cid, unknown])

      assert conn.status == 400

      assert conn.resp_body ==
               JSON.encode!(%{
                 "error" => "BlockNotFound",
                 "message" => "no stored block at one of the given CIDs"
               })
    end

    test "the same CID asked for twice is one block, not a not-found", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")

      assert get_blocks(ctx.alice.did, [cid, cid]).status == 200
    end

    test "a single cids parameter is accepted, being one CID", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")

      conn =
        xrpc_get("/xrpc/com.atproto.sync.getBlocks?did=#{enc(ctx.alice.did)}&cids=#{enc(cid)}")

      assert conn.status == 200
    end

    test "a repo this server does not host is RepoNotFound" do
      conn =
        xrpc_get(
          "/xrpc/com.atproto.sync.getBlocks?did=#{enc("did:web:localhost%3A4000:user:nobody")}&cids=bafy"
        )

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "RepoNotFound"
    end

    test "did and cids are required" do
      assert xrpc_get("/xrpc/com.atproto.sync.getBlocks").status == 400
      assert xrpc_get("/xrpc/com.atproto.sync.getBlocks?did=did:web:x").status == 400
    end
  end

  describe "getRecord" do
    test "answers a CAR holding the record and the path to it", ctx do
      cid = write_post(ctx.alice, ctx.token, "hello", "1")

      conn = get_record(ctx.alice.did, collection(), "1")

      assert conn.status == 200
      assert ["application/vnd.ipld.car" <> _] = get_resp_header(conn, "content-type")

      {roots, blocks} = Car.decode(conn.resp_body)

      assert roots == [CID.parse(commit(ctx.alice.did))]
      assert blocks[CID.parse(cid)] == block_bytes(ctx.alice.did, cid)
      assert Map.has_key?(blocks, CID.parse(root(ctx.alice.did)))
    end

    # More than one record makes the MST more than one node, so a CAR that
    # answered only the record block would be caught here rather than in the
    # single-record case where the root node is the only thing between them.
    test "carries every node on the path to the record", ctx do
      for n <- 1..6, do: write_post(ctx.alice, ctx.token, "post #{n}", Integer.to_string(n))

      conn = get_record(ctx.alice.did, collection(), "4")

      {roots, blocks} = Car.decode(conn.resp_body)

      assert roots == [CID.parse(commit(ctx.alice.did))]
      assert map_size(blocks) > 2
      assert Enum.all?(blocks, fn {_cid, bytes} -> is_binary(bytes) end)
      assert reachable_from_root(blocks, root(ctx.alice.did), record_cid(ctx.alice.did, "4"))
    end

    test "a record the repo does not have is RecordNotFound", ctx do
      write_post(ctx.alice, ctx.token, "hello", "1")

      conn = get_record(ctx.alice.did, collection(), "999")

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "RecordNotFound"
    end

    test "a repo this server does not host is RepoNotFound" do
      conn =
        xrpc_get(
          "/xrpc/com.atproto.sync.getRecord?did=#{enc("did:web:localhost%3A4000:user:nobody")}&collection=#{enc(collection())}&rkey=1"
        )

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "RepoNotFound"
    end

    test "did, collection and rkey are required" do
      assert xrpc_get("/xrpc/com.atproto.sync.getRecord").status == 400

      assert xrpc_get("/xrpc/com.atproto.sync.getRecord?did=did:web:x").status == 400
    end
  end

  defp write_post(user, token, text, rkey) do
    conn =
      xrpc_post(
        "/xrpc/com.atproto.repo.createRecord",
        %{
          "repo" => user.did,
          "collection" => collection(),
          "rkey" => rkey,
          "record" => post_record(text)
        },
        token
      )

    assert conn.status == 200
    JSON.decode!(conn.resp_body)["cid"]
  end

  defp get_blocks(did, cid_strings) do
    query = Enum.map_join(cid_strings, "", &("&cids=" <> enc(&1)))

    xrpc_get("/xrpc/com.atproto.sync.getBlocks?did=#{enc(did)}" <> query)
  end

  defp get_record(did, collection, rkey) do
    xrpc_get(
      "/xrpc/com.atproto.sync.getRecord?did=#{enc(did)}&collection=#{enc(collection)}&rkey=#{enc(rkey)}"
    )
  end

  defp commit(did), do: RepoStore.get_meta("commit:" <> did)
  defp root(did), do: RepoStore.get_meta("root:" <> did)

  defp block_bytes(did, cid), do: RepoStore.get_block(did, cid).data

  defp record_cid(did, rkey), do: RepoStore.get_record(did, collection(), rkey).cid

  # Whether the CAR a consumer got is enough to walk from the root to the
  # record on its own: every node the stored tree reaches on the way has to be
  # in the answer.
  defp reachable_from_root(blocks, root_string, target_string) do
    blocks
    |> Map.new(fn {cid, bytes} -> {CID.to_string(cid), bytes} end)
    |> walk(root_string, target_string, MapSet.new())
  end

  defp walk(blocks, node, target, seen) do
    cond do
      MapSet.member?(seen, node) ->
        false

      node == target ->
        true

      not Map.has_key?(blocks, node) ->
        false

      true ->
        case Pesque.CBOR.decode(blocks[node]) do
          {%{"l" => left, "e" => entries}, _} ->
            children =
              [
                left
                | Enum.flat_map(entries, fn %{"t" => t, "v" => v} -> [t, v] end)
              ]
              |> Enum.filter(&is_struct(&1, CID))
              |> Enum.map(&CID.to_string/1)

            children
            |> Enum.map(&walk(blocks, &1, target, MapSet.put(seen, node)))
            |> Enum.any?(& &1)

          _ ->
            false
        end
    end
  end
end
