defmodule PesqueWeb.AccountActivationTest do
  @moduledoc """
  deactivateAccount and activateAccount, checked from both sides: what a write
  gets, what the two status endpoints report, and what a consumer replaying the
  firehose from before the change hears.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.RepoStore

  @deactivate_path "/xrpc/com.atproto.server.deactivateAccount"
  @activate_path "/xrpc/com.atproto.server.activateAccount"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  describe "deactivateAccount" do
    test "needs a token", ctx do
      assert xrpc_post(@deactivate_path, %{}, nil).status == 401
      assert Accounts.repo_active?(ctx.alice.did)
    end

    test "answers an empty object and records the account as inactive", ctx do
      write_post(ctx.alice, ctx.token)

      assert xrpc_post(@deactivate_path, %{}, ctx.token).status == 200
      refute Accounts.repo_active?(ctx.alice.did)
    end

    # The rows stay, so a deactivated account is still an account: a mirror
    # asking about it gets an answer rather than a not-found.
    test "the account still resolves and keeps its repo", ctx do
      write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      assert Accounts.repo_did(ctx.alice.did) == {:ok, ctx.alice.did}
      assert Accounts.get_user(ctx.alice.did)
      assert RepoStore.get_meta("rev:" <> ctx.alice.did)
    end

    test "a deactivated account cannot write", ctx do
      write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      for path <- ["/xrpc/com.atproto.repo.createRecord", "/xrpc/com.atproto.repo.putRecord"] do
        conn = xrpc_post(path, record_params(ctx.alice), ctx.token)

        assert conn.status == 400
        assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
      end

      delete =
        xrpc_post(
          "/xrpc/com.atproto.repo.deleteRecord",
          %{"repo" => ctx.alice.did, "collection" => collection(), "rkey" => "1"},
          ctx.token
        )

      assert delete.status == 400
    end

    test "checkAccountStatus reports it as not activated", ctx do
      write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      status = check_account_status(ctx.alice.did)

      refute status["activated"]
      refute status["indexable"]
      assert status["repoCommit"] == RepoStore.get_meta("commit:" <> ctx.alice.did)
    end

    test "getRepoStatus agrees with checkAccountStatus", ctx do
      write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      refute repo_status(ctx.alice.did)["active"]
      assert repo_status(ctx.alice.did)["status"] == "deactivated"
      refute check_account_status(ctx.alice.did)["activated"]
    end

    test "listRepos reports it as deactivated too", ctx do
      write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      entry =
        xrpc_get("/xrpc/com.atproto.sync.listRepos")
        |> json_body()
        |> Map.fetch!("repos")
        |> Enum.find(&(&1["did"] == ctx.alice.did))

      refute entry["active"]
      assert entry["status"] == "deactivated"
    end

    test "the sync block endpoints answer RepoDeactivated", ctx do
      cid = write_post(ctx.alice, ctx.token)

      xrpc_post(@deactivate_path, %{}, ctx.token)

      blocks =
        xrpc_get("/xrpc/com.atproto.sync.getBlocks?did=#{enc(ctx.alice.did)}&cids=#{enc(cid)}")

      assert blocks.status == 400
      assert JSON.decode!(blocks.resp_body)["error"] == "RepoDeactivated"

      record =
        xrpc_get(
          "/xrpc/com.atproto.sync.getRecord?did=#{enc(ctx.alice.did)}&collection=#{enc(collection())}&rkey=1"
        )

      assert record.status == 400
      assert JSON.decode!(record.resp_body)["error"] == "RepoDeactivated"
    end

    test "an #account frame goes out with active false, and replays", ctx do
      write_post(ctx.alice, ctx.token)

      cursor = RepoStore.max_seq()
      Registry.register(Pesque.EventRegistry, :firehose, [])

      assert xrpc_post(@deactivate_path, %{}, ctx.token).status == 200

      assert_receive {:firehose_frame, frame}
      {header, body} = decode(frame)

      assert header == %{"op" => 1, "t" => "#account"}
      assert body["did"] == ctx.alice.did
      assert body["status"] == "deactivated"
      refute body["active"]
      assert body["seq"] == cursor + 1

      assert [^frame] = RepoStore.events_after(cursor)

      assert {:push, [{:binary, replayed} | _], _state} =
               PesqueWeb.Firehose.init(%{cursor: cursor})

      assert replayed == frame
    end

    # A recommendation, not an instruction: the lexicon says how long to hold on
    # to the account, and nothing here deletes anything.
    test "deleteAfter is recorded as no instruction and deletes nothing", ctx do
      write_post(ctx.alice, ctx.token)

      conn = xrpc_post(@deactivate_path, %{"deleteAfter" => "2030-01-01T00:00:00Z"}, ctx.token)

      assert conn.status == 200
      assert Accounts.get_user(ctx.alice.did)
      assert RepoStore.block_count(ctx.alice.did) > 0
    end
  end

  describe "activateAccount" do
    test "needs a token" do
      assert xrpc_post(@activate_path, %{}, nil).status == 401
    end

    test "answers an empty object and restores writes", ctx do
      write_post(ctx.alice, ctx.token)
      xrpc_post(@deactivate_path, %{}, ctx.token)

      assert xrpc_post(@activate_path, %{}, ctx.token).status == 200
      assert Accounts.repo_active?(ctx.alice.did)
      assert write_post(ctx.alice, ctx.token, "after activation")
    end

    test "both status endpoints report it as active again", ctx do
      write_post(ctx.alice, ctx.token)
      xrpc_post(@deactivate_path, %{}, ctx.token)
      xrpc_post(@activate_path, %{}, ctx.token)

      assert repo_status(ctx.alice.did)["active"]
      assert check_account_status(ctx.alice.did)["activated"]
    end

    test "the sync block endpoints serve again", ctx do
      cid = write_post(ctx.alice, ctx.token)
      xrpc_post(@deactivate_path, %{}, ctx.token)
      xrpc_post(@activate_path, %{}, ctx.token)

      assert xrpc_get(
               "/xrpc/com.atproto.sync.getBlocks?did=#{enc(ctx.alice.did)}&cids=#{enc(cid)}"
             ).status ==
               200
    end

    test "an #account frame goes out with no status, and replays", ctx do
      write_post(ctx.alice, ctx.token)
      xrpc_post(@deactivate_path, %{}, ctx.token)

      cursor = RepoStore.max_seq()
      Registry.register(Pesque.EventRegistry, :firehose, [])

      assert xrpc_post(@activate_path, %{}, ctx.token).status == 200

      assert_receive {:firehose_frame, frame}
      {header, body} = decode(frame)

      assert header == %{"op" => 1, "t" => "#account"}
      assert body["did"] == ctx.alice.did
      assert body["active"]
      refute body["status"]
      assert body["seq"] == cursor + 1

      assert [^frame] = RepoStore.events_after(cursor)
    end
  end

  defp write_post(user, token, text \\ "hello") do
    conn = xrpc_post("/xrpc/com.atproto.repo.createRecord", record_params(user, text), token)

    assert conn.status == 200
    JSON.decode!(conn.resp_body)["cid"]
  end

  defp record_params(user, text \\ "hello") do
    %{
      "repo" => user.did,
      "collection" => collection(),
      "record" => post_record(text)
    }
  end

  defp repo_status(did) do
    xrpc_get("/xrpc/com.atproto.sync.getRepoStatus?did=#{enc(did)}") |> json_body()
  end

  defp check_account_status(did) do
    xrpc_get("/xrpc/com.atproto.server.checkAccountStatus?did=#{enc(did)}") |> json_body()
  end

  defp json_body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end
end
