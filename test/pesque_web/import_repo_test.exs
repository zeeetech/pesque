defmodule PesqueWeb.ImportRepoTest do
  @moduledoc """
  importRepo over real requests.

  A CAR is what a repo is moved as, so the round trip is the test: export with
  getRepo, import the bytes back, and the records have to read the same. The
  import signs a new commit with this server's key for the DID, so the head
  moves; the records are content-addressed and must not.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.Car
  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Lexicon
  alias Pesque.RepoImport
  alias Pesque.RepoStore

  @import "/xrpc/com.atproto.repo.importRepo"

  setup do
    alice = insert_repo_account("alice")

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

  test "an active import persists and broadcasts one replayable #sync", ctx do
    write_post(ctx.alice, ctx.token, "imported", "1")
    car = export(ctx.alice.did)
    cursor = RepoStore.event_cursor()
    Registry.register(Pesque.EventRegistry, :firehose, [])

    assert import_repo(ctx.token, car).status == 200

    assert_receive {:firehose_frame, frame}
    refute_receive {:firehose_frame, _extra}
    {header, body} = decode(frame)

    assert header == %{"op" => 1, "t" => "#sync"}
    assert body["did"] == ctx.alice.did
    assert body["seq"] == cursor + 1
    assert {:ok, _, 0} = DateTime.from_iso8601(body["time"])

    head = RepoStore.get_meta("commit:" <> ctx.alice.did)
    rev = RepoStore.get_meta("rev:" <> ctx.alice.did)
    head_cid = CID.parse(head)
    assert body["rev"] == rev

    {roots, blocks} = Car.decode(body["blocks"].data)
    assert roots == [head_cid]
    assert blocks == %{head_cid => RepoStore.get_block(ctx.alice.did, head).data}

    commit = CBOR.decode!(blocks[head_cid])
    assert commit["did"] == ctx.alice.did
    assert commit["rev"] == rev
    assert %CBOR.Bytes{} = commit["sig"]
    assert CID.from_data(blocks[head_cid]) == head_cid
    assert RepoStore.events_after(cursor) == [frame]
  end

  test "an inactive import does not emit a sync before activation" do
    alice = create_repo_account("inactive-import")
    did = alice.did
    car = export(did)
    assert {:ok, imported} = Car.decode_repo(car)

    assert {:ok, ^did} = Accounts.deactivate_account(alice)
    cursor = RepoStore.event_cursor()

    assert {:ok, ^did} = RepoImport.persist_import(did, imported)

    assert RepoStore.event_cursor() == cursor
    assert RepoStore.events_after(cursor) == []

    assert {:ok, ^did} = Accounts.activate_account(Accounts.get_user(did))

    [account_frame, sync_frame] = RepoStore.events_after(cursor)
    {account_header, account_body} = decode(account_frame)
    {sync_header, sync_body} = decode(sync_frame)
    assert account_header["t"] == "#account"
    assert sync_header["t"] == "#sync"
    assert account_body["seq"] == cursor + 1
    assert sync_body["seq"] == cursor + 2
    assert sync_body["did"] == did
  end

  test "a failing active import rolls back the replacement and emits no event", ctx do
    write_post(ctx.alice, ctx.token, "kept", "1")
    before_records = records(ctx.alice.did)
    before_head = RepoStore.get_meta("commit:" <> ctx.alice.did)
    car = export(ctx.alice.did)
    assert {:ok, imported} = Car.decode_repo(car)
    [{_key, {cid, data}} | _rest] = Map.to_list(imported.records)
    invalid = %{imported | records: %{"invalid-key" => {cid, data}}}
    cursor = RepoStore.event_cursor()
    Registry.register(Pesque.EventRegistry, :firehose, [])

    assert_raise MatchError, fn ->
      RepoImport.persist_import(ctx.alice.did, invalid)
    end

    refute_receive {:firehose_frame, _frame}
    assert RepoStore.event_cursor() == cursor
    assert RepoStore.events_after(cursor) == []
    assert RepoStore.get_meta("commit:" <> ctx.alice.did) == before_head
    assert records(ctx.alice.did) == before_records
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
    cursor = RepoStore.event_cursor()

    conn = import_repo(ctx.token, "not a car at all")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert records(ctx.alice.did) == before
    assert RepoStore.event_cursor() == cursor
    assert RepoStore.events_after(cursor) == []
  end

  # The commit in the CAR names the repo it came from. Importing one into a
  # different account would store another repo's records under this DID, so it
  # is refused before anything is written.
  test "a CAR whose commit names another repo is refused", ctx do
    bob = insert_repo_account("bob")
    write_post(bob, token(bob), "bob's post", "1")
    car = export(bob.did)

    write_post(ctx.alice, ctx.token, "alice's post", "1")
    before = records(ctx.alice.did)
    cursor = RepoStore.event_cursor()

    conn = import_repo(ctx.token, car)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert records(ctx.alice.did) == before
    assert RepoStore.event_cursor() == cursor
    assert RepoStore.events_after(cursor) == []
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

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
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
