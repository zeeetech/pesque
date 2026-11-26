defmodule PesqueWeb.SyncReposByCollectionTest do
  use PesqueWeb.ConnCase, async: false

  alias Pesque.Repo
  alias Pesque.RepoStore.Record

  @path "/xrpc/com.atproto.sync.listReposByCollection"

  setup do
    alice = insert_repo_account("alice")
    bob = insert_repo_account("bob")

    %{alice: alice, bob: bob, token: token(alice)}
  end

  test "is public and requires a collection" do
    conn = xrpc_get(@path)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "returns distinct DIDs in stable keyset pages", ctx do
    write_post(ctx.alice, ctx.token, "first", "1")
    write_post(ctx.alice, ctx.token, "second", "2")
    write_post(ctx.bob, token(ctx.bob), "third", "1")

    first =
      xrpc_get(@path <> "?collection=#{enc(collection())}&limit=1")
      |> response_body()

    assert [%{"did" => first_did}] = first["repos"]
    assert first["cursor"] == first_did

    second =
      xrpc_get(
        @path <>
          "?collection=#{enc(collection())}&limit=1&cursor=#{enc(first["cursor"])}"
      )
      |> response_body()

    assert [%{"did" => second_did}] = second["repos"]
    assert second_did > first_did
    refute Map.has_key?(second, "cursor")
  end

  test "includes records from deactivated accounts", ctx do
    write_post(ctx.alice, ctx.token, "hello", "1")
    assert xrpc_post("/xrpc/com.atproto.server.deactivateAccount", %{}, ctx.token).status == 200

    body =
      xrpc_get(@path <> "?collection=#{enc(collection())}")
      |> response_body()

    assert ctx.alice.did in Enum.map(body["repos"], & &1["did"])
  end

  test "uses a default limit of 500", _ctx do
    insert_collection_repos(501)

    body =
      xrpc_get(@path <> "?collection=#{enc(collection())}")
      |> response_body()

    assert length(body["repos"]) == 500
    assert body["cursor"] == body["repos"] |> List.last() |> Map.fetch!("did")
  end

  test "caps the limit at 2000 and continues from the last returned DID", _ctx do
    insert_collection_repos(2001)

    first =
      xrpc_get(@path <> "?collection=#{enc(collection())}&limit=5000")
      |> response_body()

    assert length(first["repos"]) == 2000
    assert first["cursor"] == first["repos"] |> List.last() |> Map.fetch!("did")

    second =
      xrpc_get(
        @path <>
          "?collection=#{enc(collection())}&limit=5000&cursor=#{enc(first["cursor"])}"
      )
      |> response_body()

    assert length(second["repos"]) == 1
    [%{"did" => last_did}] = second["repos"]
    assert last_did > first["cursor"]
    refute Map.has_key?(second, "cursor")
  end

  test "listBlobs rejects since and still lists blobs without it", ctx do
    base = "/xrpc/com.atproto.sync.listBlobs?did=#{enc(ctx.alice.did)}"

    rejected = xrpc_get(base <> "&since=3")
    assert rejected.status == 400
    assert JSON.decode!(rejected.resp_body)["error"] == "InvalidRequest"

    accepted = xrpc_get(base)
    assert accepted.status == 200
    assert JSON.decode!(accepted.resp_body)["cids"] == []
  end

  defp insert_collection_repos(count) do
    inserted_at = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      for n <- 1..count do
        %{
          did: "did:plc:collection-test-" <> String.pad_leading(Integer.to_string(n), 4, "0"),
          collection: collection(),
          rkey: "record",
          cid: "cid-#{n}",
          data: <<>>,
          inserted_at: inserted_at
        }
      end

    Repo.insert_all(Record, rows)
    :ok
  end

  defp write_post(user, access_token, text, rkey) do
    conn =
      xrpc_post(
        "/xrpc/com.atproto.repo.createRecord",
        %{
          "repo" => user.did,
          "collection" => collection(),
          "rkey" => rkey,
          "record" => post_record(text)
        },
        access_token
      )

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp response_body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
