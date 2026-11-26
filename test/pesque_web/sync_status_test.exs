defmodule PesqueWeb.SyncStatusTest do
  @moduledoc """
  The two endpoints a Relay or a crawling AppView asks before it mirrors
  anything: getRepoStatus for one DID, listRepos for the whole server.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.RepoStore

  setup do
    alice = insert_repo_account("alice")
    bob = insert_repo_account("bob")

    %{alice: alice, bob: bob, token: token(alice)}
  end

  test "getRepoStatus reports a repo that has been written to", ctx do
    write_post(ctx.alice, "hello", ctx.token)

    body = status(ctx.alice.did)

    assert body["did"] == ctx.alice.did
    assert body["active"]
    assert body["rev"]
  end

  # Account activity is independent of whether an import has initialized its
  # repo yet.
  test "getRepoStatus reports an active account without a rev" do
    carol = provision("carol")

    body = status(carol.did)

    assert body["active"]
    refute Map.has_key?(body, "rev")
    refute Map.has_key?(body, "status")
  end

  test "getRepoStatus reports a deactivated headless account without a rev" do
    carol = provision("carol")
    assert {:ok, _} = Accounts.deactivate_account(carol)

    body = status(carol.did)

    refute body["active"]
    assert body["status"] == "deactivated"
    refute Map.has_key?(body, "rev")
  end

  test "getRepoStatus reports a rev independently of an active head", ctx do
    RepoStore.put_meta!("rev:" <> ctx.alice.did, "active-rev")

    body = status(ctx.alice.did)

    assert body["active"]
    assert body["rev"] == "active-rev"
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
    assert by_did[ctx.alice.did]["active"]
    assert by_did[ctx.bob.did]["active"]
    assert Enum.all?(body["repos"], &(is_binary(&1["head"]) and is_binary(&1["rev"])))
    assert by_did[ctx.alice.did]["rev"] == status(ctx.alice.did)["rev"]
    assert by_did[ctx.alice.did]["head"] == Pesque.RepoStore.get_meta("commit:" <> ctx.alice.did)
    assert by_did[ctx.bob.did]["rev"] == status(ctx.bob.did)["rev"]
  end

  test "local account creation returns with a durable genesis listed by listRepos" do
    cursor = RepoStore.max_seq()
    username = unique("carol")

    assert {:ok, user} =
             Accounts.create_account(
               username <> ".localhost",
               username <> "@localhost",
               "hunter2hunter2"
             )

    head = RepoStore.get_meta("commit:" <> user.did)
    root = RepoStore.get_meta("root:" <> user.did)
    rev = RepoStore.get_meta("rev:" <> user.did)

    assert is_binary(head)
    assert is_binary(root)
    assert is_binary(rev)
    assert RepoStore.get_block(user.did, head)
    assert RepoStore.get_block(user.did, root)

    entry = Enum.find(repos()["repos"], &(&1["did"] == user.did))
    assert entry["head"] == head
    assert entry["rev"] == rev

    events = RepoStore.events_after(cursor)
    assert length(events) == 2

    assert {:ok, :stopped} = RepoServer.stop(user.did)
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    assert is_map(RepoServer.entries(pid))

    assert RepoStore.get_meta("commit:" <> user.did) == head
    assert RepoStore.get_meta("root:" <> user.did) == root
    assert RepoStore.get_meta("rev:" <> user.did) == rev
    assert RepoStore.events_after(cursor) == events
  end

  test "listRepos omits a headless account" do
    carol = provision("carol")

    refute Enum.any?(repos()["repos"], &(&1["did"] == carol.did))
  end

  test "listRepos keeps a deactivated repo's head and rev", ctx do
    write_post(ctx.alice, "hello", ctx.token)
    assert {:ok, _} = Accounts.deactivate_account(ctx.alice)

    entry = Enum.find(repos()["repos"], &(&1["did"] == ctx.alice.did))

    refute entry["active"]
    assert entry["status"] == "deactivated"
    assert is_binary(entry["head"])
    assert is_binary(entry["rev"])
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

  # These direct rows model synthetic headless import states. Normal local
  # account creation initializes the repo before it returns.
  defp provision(name) do
    insert_account(name)
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
