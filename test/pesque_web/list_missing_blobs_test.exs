defmodule PesqueWeb.ListMissingBlobsTest do
  @moduledoc """
  listMissingBlobs: the blob refs the account's records name that this server
  does not hold. This is what a migration uploads next, so a blob it already
  has must not be reported and one it does not must be.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Blob
  alias Pesque.CID

  @path "/xrpc/com.atproto.repo.listMissingBlobs"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "reports a referenced-but-absent blob and not a present one", ctx do
    {:ok, present} = Blob.upload(ctx.alice.did, "hello", "image/png")
    absent = CID.to_string(CID.from_data("never uploaded", CID.raw()))

    write_record(ctx, [blob_ref(present.cid, 5), blob_ref(absent, 3)])

    conn = xrpc_get(@path, ctx.token)
    assert conn.status == 200

    body = JSON.decode!(conn.resp_body)
    cids = Enum.map(body["blobs"], & &1["cid"])

    assert absent in cids
    refute present.cid in cids

    assert Enum.all?(
             body["blobs"],
             &(&1["recordUri"] == "at://#{ctx.alice.did}/#{collection()}/1")
           )
  end

  test "needs a token" do
    assert xrpc_get(@path).status == 401
  end

  test "an account with no records has nothing missing", ctx do
    conn = xrpc_get(@path, ctx.token)

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"blobs" => []}
  end

  defp write_record(ctx, blobs) do
    record =
      post_record("with blobs")
      |> Map.put("blobs", blobs)

    conn =
      xrpc_post(
        "/xrpc/com.atproto.repo.createRecord",
        %{
          "repo" => ctx.alice.did,
          "collection" => collection(),
          "rkey" => "1",
          "record" => record,
          "validate" => false
        },
        ctx.token
      )

    assert conn.status == 200
  end

  defp blob_ref(cid, size) do
    %{
      "$type" => "blob",
      "ref" => %{"$link" => cid},
      "mimeType" => "image/png",
      "size" => size
    }
  end
end
