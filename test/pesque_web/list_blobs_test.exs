defmodule PesqueWeb.ListBlobsTest do
  @moduledoc """
  sync.listBlobs: the blob CIDs this server holds for a repo, public, with the
  repo-status errors a mirror reads.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.Blob

  @path "/xrpc/com.atproto.sync.listBlobs"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "lists the blob CIDs this server holds for the repo", ctx do
    {:ok, one} = Blob.upload(ctx.alice.did, "hello", "image/png")
    {:ok, two} = Blob.upload(ctx.alice.did, "world", "image/jpeg")

    body = list_blobs(ctx.alice.did)

    assert Enum.sort(body["cids"]) == Enum.sort([one.cid, two.cid])
  end

  test "needs a did" do
    conn = xrpc_get(@path)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "a repo this server does not host answers RepoNotFound" do
    conn = xrpc_get("#{@path}?did=#{enc("did:web:elsewhere.example")}")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "RepoNotFound"
  end

  test "a deactivated repo answers RepoDeactivated", ctx do
    {:ok, _blob} = Blob.upload(ctx.alice.did, "hello", "image/png")
    assert {:ok, _did} = Accounts.deactivate_account(ctx.alice)

    conn = xrpc_get("#{@path}?did=#{enc(ctx.alice.did)}")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "RepoDeactivated"
  end

  defp list_blobs(did) do
    conn = xrpc_get("#{@path}?did=#{enc(did)}")

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
