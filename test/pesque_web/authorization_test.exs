defmodule PesqueWeb.AuthorizationTest do
  @moduledoc """
  The write boundary over real requests: the token decides the target, and a
  body naming someone else's repo gets a 400 and changes nothing.

  ConnTest because that is the only layer where the plug, the guard, and the
  repo are in play at once. The unit tests call Accounts directly and cannot
  see a token decide anything.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.CID
  alias Pesque.Did
  alias Pesque.Repo
  alias Pesque.RepoStore

  setup do
    alice = create_account("alice")
    bob = create_account("bob")

    %{
      alice: alice,
      bob: bob,
      alice_token: token(alice),
      bob_token: token(bob)
    }
  end

  test "alice's token writing to bob's repo by bob's did is refused and changes nothing", ctx do
    seed(ctx.bob, ctx.bob_token)
    before = snapshot(ctx.bob)

    conn = create_record(ctx.bob.did, ctx.alice_token)

    assert conn.status == 400
    assert snapshot(ctx.bob) == before, "bob's repo changed"
    refute wrote(ctx.bob, "from alice")
  end

  test "alice's token writing to bob's repo by bob's handle is refused too", ctx do
    seed(ctx.bob, ctx.bob_token)
    before = snapshot(ctx.bob)

    conn = create_record(ctx.bob.handle, ctx.alice_token)

    assert conn.status == 400
    assert snapshot(ctx.bob) == before, "bob's repo changed"
    refute wrote(ctx.bob, "from alice")
  end

  test "put and delete are guarded the way create is", ctx do
    seed(ctx.bob, ctx.bob_token)
    before = snapshot(ctx.bob)

    for path <- ["putRecord", "deleteRecord"] do
      for repo <- [ctx.bob.did, ctx.bob.handle] do
        params = %{"repo" => repo, "collection" => "app.bsky.feed.post", "rkey" => "bobs"}

        conn = xrpc_post("/xrpc/com.atproto.repo.#{path}", params, ctx.alice_token)

        assert conn.status == 400, "#{path} took a cross-account write"
        assert snapshot(ctx.bob) == before, "bob's repo changed through #{path}"
      end
    end
  end

  test "alice writing to her own repo by her own handle succeeds", ctx do
    conn = create_record(ctx.alice.handle, ctx.alice_token)

    assert conn.status == 200

    assert %{"uri" => uri, "cid" => cid, "commit" => %{"cid" => commit, "rev" => rev}} =
             JSON.decode!(conn.resp_body)

    assert String.starts_with?(uri, "at://#{ctx.alice.did}/app.bsky.feed.post/")
    assert is_binary(cid)
    assert is_binary(commit)
    assert is_binary(rev)
    assert wrote(ctx.alice, "from alice")
  end

  test "alice writing to her own repo by her own did succeeds", ctx do
    assert create_record(ctx.alice.did, ctx.alice_token).status == 200
  end

  # refreshSession answering with the first account's handle would hand every
  # caller on the server somebody else's identity.
  test "refreshSession answers for the account that owns the refresh token", ctx do
    for account <- [ctx.alice, ctx.bob] do
      session = Accounts.issue_session(account.did)
      conn = xrpc_post("/xrpc/com.atproto.server.refreshSession", %{}, session.refresh_jwt)

      assert conn.status == 200
      assert %{"handle" => handle, "did" => did} = JSON.decode!(conn.resp_body)
      assert handle == account.handle
      assert did == account.did
    end
  end

  test "getSession answers for the account that owns the access token", ctx do
    for {token, account} <- [{ctx.alice_token, ctx.alice}, {ctx.bob_token, ctx.bob}] do
      conn = xrpc_get("/xrpc/com.atproto.server.getSession", token)

      assert conn.status == 200
      assert %{"handle" => handle, "did" => did} = JSON.decode!(conn.resp_body)
      assert handle == account.handle
      assert did == account.did
    end
  end

  # A validly signed token for an account that does not exist has no one
  # behind it, so it authenticates nothing.
  test "a valid token for a nonexistent account does not authenticate" do
    ghost = ghost_did()

    conn = create_record(ghost, mint_access(ghost))

    assert conn.status == 401
    assert %{"error" => "AuthenticationRequired"} = JSON.decode!(conn.resp_body)
    assert xrpc_get("/xrpc/com.atproto.server.getSession", mint_access(ghost)).status == 401

    assert xrpc_post("/xrpc/com.atproto.server.refreshSession", %{}, mint_refresh(ghost)).status ==
             401

    assert Accounts.repo_did(ghost) == :error
  end

  # The token outlives the signature check: what stops it is that there is no
  # account left to be.
  test "a token for a deleted account stops authenticating", ctx do
    token = mint_access(ctx.bob.did)
    assert create_record(ctx.bob.did, token).status == 200

    Repo.delete_all(from u in User, where: u.did == ^ctx.bob.did)

    assert create_record(ctx.bob.did, token).status == 401
    assert xrpc_get("/xrpc/com.atproto.server.getSession", token).status == 401
  end

  test "the bare server did and handle are not accounts under path_multi", ctx do
    assert Accounts.repo_did(Pesque.Identity.did()) == :error
    assert Accounts.repo_did(Pesque.Identity.handle()) == :error
    assert create_record(Pesque.Identity.handle(), ctx.alice_token).status == 400
  end

  # Non-enumerability is why both answer with the same thing: a token holder
  # must not be able to ask which DIDs this server hosts.
  test "a repo that exists but is not yours is indistinguishable from one that does not", ctx do
    seed(ctx.bob, ctx.bob_token)

    existing = create_record(ctx.bob.did, ctx.alice_token)
    missing = create_record(ghost_did(), ctx.alice_token)

    assert existing.status == missing.status
    assert existing.resp_headers == missing.resp_headers
    assert existing.resp_body == missing.resp_body

    taken = create_record(ctx.bob.handle, ctx.alice_token)
    free = create_record(ghost_handle(), ctx.alice_token)

    assert taken.status == free.status
    assert taken.resp_headers == free.resp_headers
    assert taken.resp_body == free.resp_body
  end

  test "reads are unauthenticated and serve any local repo", ctx do
    seed(ctx.bob, ctx.bob_token)

    record =
      xrpc_get(
        "/xrpc/com.atproto.repo.getRecord?repo=#{enc(ctx.bob.did)}&collection=app.bsky.feed.post&rkey=bobs"
      )

    assert record.status == 200
    assert %{"uri" => "at://" <> uri} = JSON.decode!(record.resp_body)
    assert uri == "#{ctx.bob.did}/app.bsky.feed.post/bobs"

    listed =
      xrpc_get(
        "/xrpc/com.atproto.repo.listRecords?repo=#{enc(ctx.bob.did)}&collection=app.bsky.feed.post"
      )

    assert listed.status == 200
    assert %{"records" => [%{"uri" => "at://" <> _}]} = JSON.decode!(listed.resp_body)

    repo = xrpc_get("/xrpc/com.atproto.sync.getRepo?did=#{enc(ctx.bob.did)}")
    assert repo.status == 200
    assert <<_::binary>> = repo.resp_body
    assert repo.resp_body == elem(snapshot(ctx.bob), 0)

    commit = xrpc_get("/xrpc/com.atproto.sync.getLatestCommit?did=#{enc(ctx.bob.did)}")
    assert commit.status == 200
    assert %{"cid" => cid, "rev" => rev} = JSON.decode!(commit.resp_body)
    assert is_binary(cid)
    assert is_binary(rev)
  end

  # describeRepo returning the server's identity for whatever repo is asked
  # hands every account but one somebody else's face.
  test "describeRepo returns the target account's identity, not the server's", ctx do
    seed(ctx.alice, ctx.alice_token)
    seed(ctx.bob, ctx.bob_token)

    for account <- [ctx.alice, ctx.bob] do
      body = described(account)

      assert body["handle"] == account.handle
      assert body["did"] == account.did
      assert body["didDoc"]["id"] == account.did
      assert body["didDoc"]["alsoKnownAs"] == ["at://" <> account.handle]
      assert published(body["didDoc"]) == account.pubkey_multibase
      assert body["collections"] == ["app.bsky.feed.post"]
      assert body["handleIsCorrect"] == true
    end

    alice = described(ctx.alice)
    bob = described(ctx.bob)
    server = Pesque.Identity.handle()

    refute alice["handle"] == bob["handle"]
    refute alice["handle"] == server
    refute bob["handle"] == server
    refute published(alice["didDoc"]) == published(bob["didDoc"])
  end

  test "reads for a repo that does not exist answer as before", ctx do
    ghost = ghost_did()

    for path <- [
          "/xrpc/com.atproto.repo.getRecord?repo=#{enc(ghost)}&collection=app.bsky.feed.post&rkey=x",
          "/xrpc/com.atproto.repo.listRecords?repo=#{enc(ghost)}&collection=app.bsky.feed.post",
          "/xrpc/com.atproto.repo.describeRepo?repo=#{enc(ghost)}",
          "/xrpc/com.atproto.sync.getRepo?did=#{enc(ghost)}",
          "/xrpc/com.atproto.sync.getLatestCommit?did=#{enc(ghost)}"
        ] do
      assert xrpc_get(path).status == 400, path
    end

    assert xrpc_get("/xrpc/com.atproto.repo.describeRepo?repo=#{enc(ctx.alice.did)}").status ==
             200
  end

  test "the accounts primitives agree with the http surface", ctx do
    assert Accounts.repo_did(ctx.alice.did) == {:ok, ctx.alice.did}
    assert Accounts.repo_did(ctx.alice.handle) == {:ok, ctx.alice.did}
    assert Accounts.repo_did(String.upcase(ctx.alice.handle)) == {:ok, ctx.alice.did}
    assert Accounts.repo_did(ctx.bob.handle) == {:ok, ctx.bob.did}

    # Syntactically ours, belongs to no account.
    assert Accounts.repo_did(ghost_did()) == :error
    assert Accounts.repo_did(ghost_handle()) == :error

    # Not ours at all.
    assert Accounts.repo_did("did:web:example.com:user:mallory") == :error
    assert Accounts.repo_did("alice.evil.example") == :error
    assert Accounts.repo_did("did:plc:abc123") == :error
    assert Accounts.repo_did(nil) == :error
    assert Accounts.repo_did("") == :error

    assert Accounts.authorize_write(ctx.alice, ctx.alice.did) == :ok
    assert Accounts.authorize_write(ctx.alice, ctx.alice.handle) == :ok
    assert Accounts.authorize_write(ctx.alice, ctx.bob.did) == {:error, :wrong_repo}
    assert Accounts.authorize_write(ctx.alice, ctx.bob.handle) == {:error, :wrong_repo}
    assert Accounts.authorize_write(ctx.alice, ghost_did()) == {:error, :wrong_repo}
    assert Accounts.authorize_write(ctx.alice, nil) == {:error, :wrong_repo}
  end

  test "uploadBlob without a token is 401 and stores nothing", ctx do
    conn =
      build_conn()
      |> put_req_header("content-type", "image/jpeg")
      |> dispatch(Endpoint, :post, "/xrpc/com.atproto.repo.uploadBlob", "hello")

    assert conn.status == 401
    assert %{"error" => "AuthenticationRequired"} = JSON.decode!(conn.resp_body)

    cid = CID.to_string(CID.from_data("hello", CID.raw()))

    assert RepoStore.get_blob(ctx.alice.did, cid) == nil
    assert RepoStore.get_blob(ctx.bob.did, cid) == nil
    refute File.exists?(Blob.path(ctx.alice.did, CID.parse(cid)))
  end

  # uploadBlob names no repo, so the only account it can touch is the one the
  # token names. What has to hold is that alice's bytes land under alice's DID
  # and are not reachable by naming bob, whatever cid is asked for.
  test "an upload lands under the uploader's did and not under anyone else's", ctx do
    conn = upload_blob(ctx.alice_token, "hello", "image/jpeg")

    assert conn.status == 200
    assert %{"blob" => %{"ref" => %{"$link" => cid}}} = JSON.decode!(conn.resp_body)

    assert Blob.fetch(ctx.alice.did, CID.parse(cid)) == {:ok, "hello", "image/jpeg"}
    assert Blob.fetch(ctx.bob.did, CID.parse(cid)) == {:error, :not_found}

    stolen = xrpc_get("/xrpc/com.atproto.sync.getBlob?did=#{enc(ctx.bob.did)}&cid=#{enc(cid)}")
    assert stolen.status == 400
    assert %{"error" => "BlobNotFound"} = JSON.decode!(stolen.resp_body)

    owner = xrpc_get("/xrpc/com.atproto.sync.getBlob?did=#{enc(ctx.alice.did)}&cid=#{enc(cid)}")
    assert owner.status == 200
    # helpers
    assert owner.resp_body == "hello"
  end

  # Nothing a request supplies becomes a path segment: the cid is parsed and
  # matched on the decoded struct before it ever names a file, so a traversal
  # attempt is refused at the edge and the blobs directory does not grow.
  test "a blob path cannot escape the blob directory", ctx do
    before = File.ls!(Pesque.Storage.blobs_dir())

    for attempt <- ["../../etc/passwd", "..%2f..%2fetc%2fpasswd", "bafkrei/../../etc/passwd"] do
      conn =
        xrpc_get("/xrpc/com.atproto.sync.getBlob?did=#{enc(ctx.alice.did)}&cid=#{enc(attempt)}")

      assert conn.status == 400, attempt
      assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
    end

    assert File.ls!(Pesque.Storage.blobs_dir()) == before

    conn = upload_blob(ctx.alice_token, "hello", "image/jpeg")
    assert conn.status == 200
    assert %{"blob" => %{"ref" => %{"$link" => cid}}} = JSON.decode!(conn.resp_body)

    assert Blob.path(ctx.alice.did, CID.parse(cid)) =~
             Pesque.Storage.blobs_dir() <> "/"
  end

  defp upload_blob(token, body, media_type) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", media_type)
    |> dispatch(Endpoint, :post, "/xrpc/com.atproto.repo.uploadBlob", body)
  end

  defp seed(user, token) do
    params = %{
      "repo" => user.did,
      "collection" => "app.bsky.feed.post",
      "rkey" => "bobs",
      "record" => post_record("seeded by " <> user.username)
    }

    assert xrpc_post("/xrpc/com.atproto.repo.createRecord", params, token).status == 200
    :ok
  end

  defp snapshot(user) do
    car = xrpc_get("/xrpc/com.atproto.sync.getRepo?did=#{enc(user.did)}")
    commit = xrpc_get("/xrpc/com.atproto.sync.getLatestCommit?did=#{enc(user.did)}")

    assert car.status == 200
    assert commit.status == 200
    {car.resp_body, JSON.decode!(commit.resp_body)}
  end

  defp wrote(user, text) do
    listed =
      xrpc_get(
        "/xrpc/com.atproto.repo.listRecords?repo=#{enc(user.did)}&collection=app.bsky.feed.post"
      )

    listed.resp_body
    |> JSON.decode!()
    |> Map.fetch!("records")
    |> Enum.any?(&(&1["value"]["text"] == text))
  end

  defp described(account) do
    conn = xrpc_get("/xrpc/com.atproto.repo.describeRepo?repo=#{enc(account.did)}")
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp create_record(repo, token) do
    params = %{
      "repo" => repo,
      "collection" => "app.bsky.feed.post",
      "record" => post_record("from alice")
    }

    xrpc_post("/xrpc/com.atproto.repo.createRecord", params, token)
  end

  defp mint_access(did) do
    now = System.system_time(:second)

    Pesque.Token.sign(
      %{"scope" => "com.atproto.access", "sub" => did, "iat" => now, "exp" => now + 3600},
      Pesque.Secret.get()
    )
  end

  defp mint_refresh(did) do
    now = System.system_time(:second)

    Pesque.Token.sign(
      %{
        "scope" => "com.atproto.refresh",
        "sub" => did,
        "jti" => "ghost-jti",
        "iat" => now,
        "exp" => now + 3600
      },
      Pesque.Secret.get()
    )
  end

  defp ghost_did, do: Did.did_for_username(:path_multi, host(), unique("ghost"))
  defp ghost_handle, do: unique("ghost") <> ".localhost"

  defp published(doc) do
    [verification] = doc["verificationMethod"]
    verification["publicKeyMultibase"]
  end

  defp host, do: Did.did_host(Pesque.hostname(), Pesque.port())
end
