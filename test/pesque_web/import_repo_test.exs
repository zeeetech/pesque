defmodule PesqueWeb.ImportRepoTest do
  @moduledoc """
  importRepo over real requests.

  A CAR is what a repo is moved as, so the round trip is the test: export with
  getRepo, import the bytes back, and the records have to read the same. The
  import signs a new commit with this server's key for the DID, so the head
  moves; the records are content-addressed and must not.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.CBOR
  alias Pesque.Lexicon
  alias Pesque.RepoStore

  @import "/xrpc/com.atproto.repo.importRepo"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "a repo exported with getRepo imports back and its records read back identically", ctx do
    for n <- 1..3, do: write_post(ctx.alice, ctx.token, "post #{n}", Integer.to_string(n))

    before = records(ctx.alice.did)
    car = export(ctx.alice.did)

    conn = import_repo(ctx.token, car)

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{}
    assert records(ctx.alice.did) == before
  end

  # The spec allows importing over a repo that already has records, and says the
  # import replaces it. A key the CAR does not carry has to be gone afterwards,
  # or a re-import of a stale export would resurrect records the source deleted.
  test "re-import replaces the repo rather than appending to it", ctx do
    write_post(ctx.alice, ctx.token, "one", "1")
    car = export(ctx.alice.did)

    write_post(ctx.alice, ctx.token, "two", "2")
    assert map_size(records(ctx.alice.did)) == 2

    assert import_repo(ctx.token, car).status == 200

    assert Map.keys(records(ctx.alice.did)) == ["1"]
    assert records(ctx.alice.did)["1"]["text"] == "one"
  end

  test "a malformed CAR is refused and leaves the repo untouched", ctx do
    write_post(ctx.alice, ctx.token, "one", "1")
    before = records(ctx.alice.did)

    conn = import_repo(ctx.token, "not a car at all")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert records(ctx.alice.did) == before
  end

  # The commit in the CAR names the repo it came from. Importing one into a
  # different account would store another repo's records under this DID, so it
  # is refused before anything is written.
  test "a CAR whose commit names another repo is refused", ctx do
    bob = create_account("bob")
    write_post(bob, token(bob), "bob's post", "1")
    car = export(bob.did)

    write_post(ctx.alice, ctx.token, "alice's post", "1")
    before = records(ctx.alice.did)

    conn = import_repo(ctx.token, car)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert records(ctx.alice.did) == before
  end

  test "the content-length header is required", ctx do
    car = export(ctx.alice.did)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/vnd.ipld.car")
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> dispatch(Endpoint, :post, @import, car)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["message"] =~ "content-length"
  end

  test "needs a token" do
    conn = import_repo(nil, "whatever")

    assert conn.status == 401
  end

  defp import_repo(token, body) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/vnd.ipld.car")
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    dispatch(conn, Endpoint, :post, @import, body)
  end

  defp export(did) do
    conn = xrpc_get("/xrpc/com.atproto.sync.getRepo?did=#{enc(did)}")

    assert conn.status == 200
    conn.resp_body
  end

  defp records(did) do
    did
    |> RepoStore.records_for()
    |> Map.new(fn %{collection: collection, rkey: rkey} ->
      data = RepoStore.get_record(did, collection, rkey).data
      {rkey, data |> CBOR.decode!() |> Lexicon.to_json()}
    end)
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
  end
end
