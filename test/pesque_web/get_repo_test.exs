defmodule PesqueWeb.GetRepoTest do
  @moduledoc """
  getRepo over real requests, with the streaming the endpoint answers from
  checked against what it used to send.

  A CAR is content-addressed: the bytes on the wire are what a consumer
  verifies, caches and dedupes against. So this asserts on the raw body against
  a CAR built the buffered way, rather than decoding both and comparing the
  maps, which would pass even if the block order changed. Block order is the
  one thing a re-parse cannot see.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query

  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.Repo
  alias Pesque.RepoStore

  @get_repo "/xrpc/com.atproto.sync.getRepo"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "answers a chunked CAR for the repo", ctx do
    write_post(ctx.alice, ctx.token, "hello", "1")

    conn = get_repo(ctx.alice.did)

    assert conn.status == 200
    assert ["application/vnd.ipld.car" <> _] = get_resp_header(conn, "content-type")
    assert byte_size(conn.resp_body) > 0
  end

  # The point of the streaming: the same bytes the buffered implementation sent,
  # which is what keeps every consumer that already fetched from this server
  # working. Rebuilt here from the store with Car.encode/2, the way send_car/3
  # still builds the getBlocks CAR, and compared as raw bytes.
  test "the streamed CAR is byte-identical to the buffered one for the same repo", ctx do
    for n <- 1..6, do: write_post(ctx.alice, ctx.token, "post #{n}", Integer.to_string(n))

    streamed = get_repo(ctx.alice.did).resp_body
    buffered = Car.encode([CID.parse(commit(ctx.alice.did))], blocks(ctx.alice.did))

    assert streamed == buffered
  end

  # A CAR that answers short looks exactly like a repo that does not have the
  # block, so the whole request fails instead. The check happens before the
  # header is written, which is what lets it still be a JSON error.
  test "a block that is not stored answers a JSON error, not a short CAR", ctx do
    write_post(ctx.alice, ctx.token, "hello", "1")

    # The commit block row is deleted while the meta row still names it, which is
    # the one block that can be named and not stored. Checked before the
    # header, so it can still be answered as JSON.
    delete_block(ctx.alice.did, commit(ctx.alice.did))

    conn = get_repo(ctx.alice.did)

    assert conn.status == 500

    assert %{"error" => "InternalServerError", "message" => message} =
             JSON.decode!(conn.resp_body)

    assert message =~ "missing"
  end

  # The other failure that has to be caught before the header: a stored CID that
  # does not parse. Same JSON-answerable shape, different reason, so the two
  # are told apart rather than one silently covering the other.
  test "a stored cid that does not parse answers a JSON error", ctx do
    write_post(ctx.alice, ctx.token, "hello", "1")

    RepoStore.insert_blocks!(ctx.alice.did, [{"not-a-cid", <<0>>}])

    conn = get_repo(ctx.alice.did)

    assert conn.status == 500

    assert %{"error" => "InternalServerError", "message" => message} =
             JSON.decode!(conn.resp_body)

    assert message =~ "block could not be decoded"
  end

  test "a repo this server does not host answers RepoNotFound as JSON", ctx do
    write_post(ctx.alice, ctx.token, "hello", "1")

    conn =
      xrpc_get("#{@get_repo}?did=#{enc("did:web:localhost%3A4000:user:nobody")}")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "RepoNotFound"
  end

  test "did is required" do
    assert xrpc_get(@get_repo).status == 400
  end

  # getBlocks is the other CAR endpoint and still answers from send_car/3, so
  # the two framings are compared against each other here as well: same store,
  # same blocks, different entry point.
  test "getRepo and getBlocks agree on the framing of a shared block", ctx do
    cid = write_post(ctx.alice, ctx.token, "hello", "1")
    root = CID.parse(commit(ctx.alice.did))

    repo = get_repo(ctx.alice.did).resp_body
    blocks_conn = get_blocks(ctx.alice.did, [cid])

    {repo_roots, repo_blocks} = Car.decode(repo)
    {blocks_roots, blocks_car} = Car.decode(blocks_conn.resp_body)

    assert repo_roots == [root]
    assert blocks_roots == [root]

    for {cid, data} <- blocks_car do
      assert repo_blocks[cid] == data
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

  defp get_repo(did), do: xrpc_get("#{@get_repo}?did=#{enc(did)}")

  defp get_blocks(did, cid_strings) do
    query = Enum.map_join(cid_strings, "", &("&cids=" <> enc(&1)))
    xrpc_get("/xrpc/com.atproto.sync.getBlocks?did=#{enc(did)}" <> query)
  end

  defp commit(did), do: RepoStore.get_meta("commit:" <> did)

  defp delete_block(did, cid_string) do
    {1, _} =
      Repo.delete_all(from(b in RepoStore.Block, where: b.did == ^did and b.cid == ^cid_string))

    :ok
  end

  # The buffered path's own view of the repo: every block, keyed by parsed CID.
  # This is the map Car.encode/2 is specified over, so comparing the streamed
  # bytes against encode/2 over this map compares the two implementations.
  defp blocks(did) do
    did
    |> RepoStore.blocks_for()
    |> Map.new(fn block -> {CID.parse(block.cid), block.data} end)
  end
end
