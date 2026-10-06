defmodule PesqueWeb.SyncStatusTest do
  @moduledoc """
  The two endpoints a Relay or a crawling AppView asks before it mirrors
  anything: getRepoStatus for one DID, listRepos for the whole server.
  """

  use PesqueWeb.ConnCase, async: false

  setup do
    alice = create_account("alice")
    bob = create_account("bob")

    %{alice: alice, bob: bob, token: token(alice)}
  end

  test "getRepoStatus reports a repo that has been written to", ctx do
    write_post(ctx.alice, "hello", ctx.token)

    body = status(ctx.alice.did)

    assert body["did"] == ctx.alice.did
    assert body["active"]
    assert body["rev"]
  end

  # An account whose repo has never been started has a users row and no
  # commit, which is exactly the state a mirror has to be told about: the
  # account exists, the repo is not being served yet.
  test "getRepoStatus reports an account that has never written as deactivated" do
    carol = provision("carol")

    body = status(carol.did)

    refute body["active"]
    assert body["status"] == "deactivated"
    assert body["rev"] == nil
  end

  test "getRepoStatus answers for a handle as well as a did", ctx do
    write_post(ctx.alice, "hello", ctx.token)

    assert status(ctx.alice.handle)["rev"] == status(ctx.alice.did)["rev"]
  end

  test "getRepoStatus says a repo this server does not host is not found" do
    conn =
      xrpc_get(
        "/xrpc/com.atproto.sync.getRepoStatus?did=#{enc("did:web:localhost%3A4000:user:nobody")}"
      )

    assert conn.status == 404
    assert JSON.decode!(conn.resp_body)["error"] == "RepoNotFound"
  end

  test "getRepoStatus needs a did" do
    conn = xrpc_get("/xrpc/com.atproto.sync.getRepoStatus")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "listRepos enumerates every hosted repo, with rev and head", ctx do
    write_post(ctx.alice, "hello", ctx.token)
    write_post(ctx.bob, "hi", token(ctx.bob))

    body = repos()

    by_did = Map.new(body["repos"], &{&1["did"], &1})

    assert map_size(by_did) == 2
    assert by_did[ctx.alice.did]["rev"] == status(ctx.alice.did)["rev"]
    assert by_did[ctx.alice.did]["head"] == Pesque.RepoStore.get_meta("commit:" <> ctx.alice.did)
    assert by_did[ctx.bob.did]["rev"] == status(ctx.bob.did)["rev"]
  end

  test "listRepos reports an account with no repo as inactive" do
    carol = provision("carol")

    entry = Enum.find(repos()["repos"], &(&1["did"] == carol.did))

    refute entry["active"]
    assert entry["status"] == "deactivated"
    assert entry["rev"] == nil
  end

  # The enumeration is public and takes no cursor from anybody, so whatever it
  # answers has to be only what the lexicon declares and nothing the users
  # table holds privately.
  test "listRepos leaks no email or password material", ctx do
    body = repos()

    refute body["cursor"]

    encoded = inspect(body)

    refute encoded =~ ctx.alice.email
    refute encoded =~ ctx.alice.password_hash
    refute encoded =~ "password"
  end

  test "listRepos pages with a cursor", ctx do
    write_post(ctx.alice, "hello", ctx.token)
    write_post(ctx.bob, "hi", token(ctx.bob))

    first = xrpc_get("/xrpc/com.atproto.sync.listRepos?limit=1") |> body()

    assert [_one] = first["repos"]
    assert first["cursor"] == "1"

    second =
      xrpc_get("/xrpc/com.atproto.sync.listRepos?limit=1&cursor=#{first["cursor"]}") |> body()

    assert [other] = second["repos"]
    assert other["did"] != hd(first["repos"])["did"]
    refute second["cursor"]
  end

  # create_account/1 in ConnCase starts the repo, which writes the genesis
  # commit. Provisioning straight through Accounts leaves the repo unstarted,
  # which is the state this endpoint has something to say about.
  defp provision(name) do
    username = unique(name)

    {:ok, user} =
      Accounts.create_account(
        username <> ".localhost",
        username <> "@localhost",
        "hunter2hunter2"
      )

    user
  end

  defp write_post(user, text, token) do
    xrpc_post(
      "/xrpc/com.atproto.repo.createRecord",
      %{"repo" => user.did, "collection" => collection(), "record" => post_record(text)},
      token
    )
  end

  defp status(did), do: read("/xrpc/com.atproto.sync.getRepoStatus?did=#{enc(did)}")

  defp repos, do: read("/xrpc/com.atproto.sync.listRepos")

  defp read(path), do: xrpc_get(path) |> body()

  defp body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
