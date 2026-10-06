defmodule PesqueWeb.AccountLifecycleTest do
  @moduledoc """
  updateHandle and the two-step deletion flow.

  Both endpoints announce themselves on the firehose, so a handle that moved and
  an account that went away are only really done when a consumer replaying from
  a cursor before the change hears about it. That is what these check alongside
  the HTTP answers.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query
  import Process, only: [alive?: 1]

  alias Pesque.Accounts
  alias Pesque.Accounts.DeletionToken
  alias Pesque.Blob
  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.Storage

  @password "hunter2hunter2"
  @update_path "/xrpc/com.atproto.identity.updateHandle"
  @request_path "/xrpc/com.atproto.server.requestAccountDelete"
  @delete_path "/xrpc/com.atproto.server.deleteAccount"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  describe "updateHandle" do
    test "needs a token" do
      conn = xrpc_post(@update_path, %{"handle" => "nope.localhost"}, nil)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "AuthenticationRequired"
    end

    test "needs a handle", ctx do
      conn = xrpc_post(@update_path, %{}, ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    end

    test "moves the handle and answers an empty object", ctx do
      new_handle = unique("renamed") <> ".localhost"

      cursor = RepoStore.max_seq()
      Registry.register(Pesque.EventRegistry, :firehose, [])

      conn = xrpc_post(@update_path, %{"handle" => new_handle}, ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}

      assert Accounts.resolve_handle(new_handle) == {:ok, ctx.alice.did}
      assert Accounts.resolve_handle(ctx.alice.handle) == {:error, :not_found}

      assert_receive {:firehose_frame, frame}
      {header, body} = decode(frame)

      assert header["t"] == "#identity"
      assert body["did"] == ctx.alice.did
      assert body["handle"] == new_handle
      assert body["seq"] == cursor + 1

      # Replayable, which is what a consumer that was offline needs.
      assert [^frame] = RepoStore.events_after(cursor)
    end

    test "the DID document publishes the handle the account now answers to", ctx do
      new_handle = unique("renamed") <> ".localhost"

      assert xrpc_post(@update_path, %{"handle" => new_handle}, ctx.token).status == 200

      {:ok, doc} = Accounts.did_document_for(ctx.alice.username)
      assert doc["alsoKnownAs"] == ["at://" <> new_handle]
      assert doc["id"] == ctx.alice.did
    end

    test "a handle another account holds is refused", ctx do
      bob = create_account("bob")

      conn = xrpc_post(@update_path, %{"handle" => bob.handle}, ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "HandleNotAvailable"
      assert Accounts.get_user(ctx.alice.did).handle == ctx.alice.handle
    end

    test "a handle under a lookalike domain is refused", ctx do
      conn = xrpc_post(@update_path, %{"handle" => "alice.notlocalhost"}, ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "HandleNotAvailable"
    end

    test "an account's own handle is not a collision with itself", ctx do
      conn = xrpc_post(@update_path, %{"handle" => ctx.alice.handle}, ctx.token)

      assert conn.status == 200
    end
  end

  describe "requestAccountDelete" do
    test "needs a token" do
      assert xrpc_post(@request_path, %{}, nil).status == 401
    end

    test "answers a token and records it against the account", ctx do
      body = request_delete(ctx.token)

      assert is_binary(body["token"])
      assert {:ok, _, 0} = DateTime.from_iso8601(body["expiresAt"])

      assert %DeletionToken{did: did} =
               Repo.one!(from t in DeletionToken, where: t.did == ^ctx.alice.did)

      assert did == ctx.alice.did
      assert is_nil(did_used_at())
    end

    # The row holds a hash, never the token: a table read out of the database
    # must not be enough to delete an account.
    test "the token is stored hashed", ctx do
      body = request_delete(ctx.token)

      assert %DeletionToken{token_hash: hash} =
               Repo.one!(from t in DeletionToken, where: t.did == ^ctx.alice.did)

      assert hash == DeletionToken.hash_token(body["token"])
      refute hash == body["token"]
    end

    test "the account still exists after asking", ctx do
      request_delete(ctx.token)

      assert Accounts.get_user(ctx.alice.did)
    end
  end

  describe "deleteAccount" do
    test "needs a token" do
      assert xrpc_post(@delete_path, delete_params("did", @password, "t"), nil).status == 401
    end

    test "needs a did, a password and a token", ctx do
      assert xrpc_post(@delete_path, %{}, ctx.token).status == 400
    end

    test "refuses a did that is not the authenticated account", ctx do
      body = request_delete(ctx.token)
      other = create_account("bob")

      conn = delete(other.did, @password, body["token"], ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
      assert Accounts.get_user(ctx.alice.did)
    end

    test "refuses the wrong password", ctx do
      body = request_delete(ctx.token)

      conn = delete(ctx.alice.did, "not-the-password", body["token"], ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "AuthenticationRequired"
      assert Accounts.get_user(ctx.alice.did)
    end

    test "refuses an unknown token as InvalidToken", ctx do
      request_delete(ctx.token)

      conn = delete(ctx.alice.did, @password, "not-a-token", ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidToken"
      assert Accounts.get_user(ctx.alice.did)
    end

    # Another account's token must not delete this account, even with this
    # account's password: the token names who authorized the deletion.
    test "refuses a token issued for another account", ctx do
      bob = create_account("bob")
      body = request_delete(token(bob))

      conn = delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidToken"
      assert Accounts.get_user(ctx.alice.did)
    end

    test "refuses an expired token as ExpiredToken", ctx do
      body = request_delete(ctx.token)

      expire!(ctx.alice.did)

      conn = delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "ExpiredToken"
      assert Accounts.get_user(ctx.alice.did)
    end

    test "a spent token cannot be spent again", ctx do
      body = request_delete(ctx.token)

      assert {:ok, _did} =
               Accounts.delete_account(ctx.alice, ctx.alice.did, @password, body["token"])

      # The account is gone, so the replay is refused before the token is even
      # looked at: the token, the password and the account all have to be live
      # at once.
      assert Accounts.get_user(ctx.alice.did) == nil
    end

    test "a token marked used answers InvalidToken", ctx do
      body = request_delete(ctx.token)
      spend!(ctx.alice.did)

      conn = delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidToken"
      assert Accounts.get_user(ctx.alice.did)
    end

    test "deletes the account and answers an empty object", ctx do
      body = request_delete(ctx.token)

      conn = delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
      assert Accounts.get_user(ctx.alice.did) == nil
    end

    test "the DID resolves as unknown everywhere afterwards", ctx do
      body = request_delete(ctx.token)

      assert xrpc_post("/xrpc/com.atproto.repo.createRecord", record_params(ctx), ctx.token).status ==
               200

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert Accounts.repo_did(ctx.alice.did) == {:error, :not_found}
      assert Accounts.resolve_handle(ctx.alice.handle) == {:error, :not_found}
      assert Accounts.did_document_for(ctx.alice.username) == {:error, :not_found}
      assert xrpc_get("/user/#{ctx.alice.username}/did.json").status == 404

      did = URI.encode_www_form(ctx.alice.did)

      # checkAccountStatus answers rather than 404s, and says not activated:
      # an AppView asking about a repo this server no longer hosts must be told
      # so in the shape it reads.
      conn = xrpc_get("/xrpc/com.atproto.server.checkAccountStatus?did=#{did}")
      assert conn.status == 200
      status = JSON.decode!(conn.resp_body)

      refute status["activated"]
      refute status["indexable"]
      assert status["repoCommit"] == nil

      refute get_record(ctx.alice)["value"]

      # getRepo answers RepoNotFound, so a mirror cannot pull a repo that is gone.
      assert xrpc_get("/xrpc/com.atproto.sync.getRepo?did=#{did}").status == 400
    end

    test "records, blocks and meta rows are gone", ctx do
      body = request_delete(ctx.token)

      assert xrpc_post("/xrpc/com.atproto.repo.createRecord", record_params(ctx), ctx.token).status ==
               200

      assert RepoStore.records_for(ctx.alice.did) != []

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert RepoStore.records_for(ctx.alice.did) == []
      assert RepoStore.blocks_for(ctx.alice.did) == []
      assert RepoStore.block_count(ctx.alice.did) == 0
      assert RepoStore.get_meta("commit:" <> ctx.alice.did) == nil
      assert RepoStore.get_meta("rev:" <> ctx.alice.did) == nil
    end

    test "the signing key file and the blob bytes are gone", ctx do
      body = request_delete(ctx.token)

      {:ok, blob} = Blob.upload(ctx.alice.did, "some bytes", "image/png")
      blob_path = Blob.path(ctx.alice.did, CID.parse(blob.cid))

      assert File.exists?(Keys.path(ctx.alice.did))
      assert File.exists?(blob_path)

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      refute File.exists?(Keys.path(ctx.alice.did))
      refute File.exists?(blob_path)
      refute File.exists?(Path.join(Storage.blobs_dir(), Storage.digest_name(ctx.alice.did)))
      assert Repo.get_by(Pesque.RepoStore.Blob, did: ctx.alice.did) == nil
    end

    test "the refresh tokens go with the account", ctx do
      body = request_delete(ctx.token)
      before = Repo.aggregate(Pesque.Accounts.RefreshToken, :count)

      assert before > 0

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert Repo.aggregate(Pesque.Accounts.RefreshToken, :count) == before - 1
    end

    test "the repo process is stopped", ctx do
      body = request_delete(ctx.token)
      did = ctx.alice.did

      assert [{pid, _}] = Registry.lookup(Pesque.RepoRegistry, did)

      delete(did, @password, body["token"], ctx.token)

      refute alive?(pid)
    end

    test "an #account deleted frame goes out before the row is gone, and replays", ctx do
      body = request_delete(ctx.token)

      cursor = RepoStore.max_seq()
      Registry.register(Pesque.EventRegistry, :firehose, [])

      assert delete(ctx.alice.did, @password, body["token"], ctx.token).status == 200

      assert_receive {:firehose_frame, frame}
      {header, account} = decode(frame)

      assert header == %{"op" => 1, "t" => "#account"}
      assert account["did"] == ctx.alice.did
      assert account["status"] == "deleted"
      refute account["active"]
      assert account["seq"] == cursor + 1

      assert [^frame] = RepoStore.events_after(cursor)

      assert {:push, [{:binary, replayed} | _], _state} =
               PesqueWeb.Firehose.init(%{cursor: cursor})

      assert replayed == frame
    end

    # The frame is written before the user row is deleted, so the log must still
    # name an account this server no longer hosts.
    test "the log keeps the deleted account's frame", ctx do
      body = request_delete(ctx.token)

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert [%RepoStore.Event{did: did}] =
               Repo.all(
                 from e in RepoStore.Event,
                   where: e.did == ^ctx.alice.did,
                   order_by: [desc: e.seq],
                   limit: 1
               )

      assert did == ctx.alice.did
    end

    test "another account is untouched", ctx do
      bob = create_account("bob")
      body = request_delete(ctx.token)

      delete(ctx.alice.did, @password, body["token"], ctx.token)

      assert Accounts.get_user(bob.did)
      assert RepoStore.get_meta("rev:" <> bob.did)
    end
  end

  defp request_delete(token) do
    conn = xrpc_post(@request_path, %{}, token)
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp delete(did, password, token, access_token) do
    xrpc_post(@delete_path, delete_params(did, password, token), access_token)
  end

  defp delete_params(did, password, token) do
    %{"did" => did, "password" => password, "token" => token}
  end

  defp record_params(ctx) do
    %{
      "repo" => ctx.alice.did,
      "collection" => collection(),
      "record" => post_record("hello")
    }
  end

  defp get_record(user) do
    path =
      "/xrpc/com.atproto.repo.getRecord?repo=#{enc(user.did)}&collection=#{enc(collection())}&rkey=1"

    conn = xrpc_get(path)
    if conn.status == 200, do: JSON.decode!(conn.resp_body), else: %{}
  end

  defp expire!(did) do
    Repo.update_all(
      from(t in DeletionToken, where: t.did == ^did),
      set: [expires_at: ~U[2000-01-01 00:00:00Z]]
    )
  end

  defp spend!(did) do
    Repo.update_all(
      from(t in DeletionToken, where: t.did == ^did),
      set: [used_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )
  end

  defp did_used_at do
    Repo.one(from t in DeletionToken, select: t.used_at, limit: 1)
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end
end
