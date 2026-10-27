defmodule PesqueWeb.AccountInviteCodesTest do
  @moduledoc """
  com.atproto.server.getAccountInviteCodes.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.InviteCode
  alias Pesque.Repo

  @path "/xrpc/com.atproto.server.getAccountInviteCodes"

  setup do
    alice = insert_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "needs a token" do
    assert xrpc_get(@path).status == 401
  end

  test "answers the codes earmarked for the account", ctx do
    {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 2, [ctx.alice.did])

    assert [entry] = read(ctx.token)["codes"]
    assert entry["code"] == code
    assert entry["available"] == 2
    assert entry["forAccount"] == ctx.alice.did
    assert entry["disabled"] == false
    assert entry["uses"] == []
    assert is_binary(entry["createdBy"])
  end

  test "a code created for nobody belongs to no account", ctx do
    {:ok, _} = Accounts.create_invite_codes(1, 1, [])

    assert read(ctx.token)["codes"] == []
  end

  test "includeUsed false drops a code with no uses left", ctx do
    {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1, [ctx.alice.did])

    Repo.update_all(
      from(i in InviteCode, where: i.code == ^code),
      set: [uses: 1, used_by: ctx.alice.did, used_at: DateTime.utc_now()]
    )

    assert read(ctx.token, "?includeUsed=false")["codes"] == []

    assert [entry] = read(ctx.token, "?includeUsed=true")["codes"]
    assert entry["available"] == 0
    assert [%{"usedBy" => _did, "usedAt" => _at}] = entry["uses"]
  end

  defp read(token, query \\ "") do
    conn = xrpc_get(@path <> query, token)

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
