defmodule PesqueWeb.InviteCodeTest do
  @moduledoc """
  Invite codes: the only way in on a server whose registration is closed, and
  as many accounts each as the operator said they buy.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.InviteCode
  alias Pesque.Did
  alias Pesque.Repo

  @path "/xrpc/com.atproto.server.createInviteCodes"
  @account_path "/xrpc/com.atproto.server.createAccount"
  @password "hunter2hunter2"

  setup do
    put_registration(:closed)
    alice = create_account("alice")

    # Minting a code is the operator's call and the plug holds the line, so
    # these tests have to be the operator. The suite runs :path_multi, where
    # there is no server identity to hold a session, so the operator is named
    # the way that topology names one.
    Application.put_env(:pesque, :admin_dids, [alice.did])
    on_exit(fn -> Application.delete_env(:pesque, :admin_dids) end)

    %{alice: alice, token: token(alice)}
  end

  # The gate is the point of the endpoint, so it gets its own test rather than
  # being only implied by every other test in this file passing.
  test "createInviteCodes refuses an account that is not the operator", _ctx do
    mallory = create_account("mallory")

    conn = xrpc_post(@path, %{"codeCount" => 1, "useCount" => 1}, token(mallory))

    assert conn.status == 403
    assert Repo.aggregate(InviteCode, :count) == 0
  end

  test "createInviteCodes needs a token", ctx do
    before = Repo.aggregate(InviteCode, :count)
    conn = xrpc_post(@path, %{"codeCount" => 1, "useCount" => 1}, nil)

    assert conn.status == 401
    assert JSON.decode!(conn.resp_body)["error"] == "AuthenticationRequired"
    assert Repo.aggregate(InviteCode, :count) == before
    assert ctx.token
  end

  test "createInviteCodes answers one group per codeCount, all distinct", ctx do
    body = codes(%{"codeCount" => 3, "useCount" => 1}, ctx.token)
    [group] = body["codes"]

    assert group["account"] == nil
    assert length(group["codes"]) == 3
    assert group["codes"] == Enum.uniq(group["codes"])
    assert Enum.all?(group["codes"], &match?(<<_::binary>>, &1))
  end

  test "createInviteCodes defaults codeCount to one and needs a useCount", ctx do
    [group] = codes(%{"useCount" => 1}, ctx.token)["codes"]
    assert length(group["codes"]) == 1

    conn = xrpc_post(@path, %{}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "createInviteCodes refuses a count that is not a positive integer", ctx do
    conn = xrpc_post(@path, %{"codeCount" => 0, "useCount" => 1}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "createInviteCodes refuses a useCount that is not a positive integer", ctx do
    conn = xrpc_post(@path, %{"codeCount" => 1, "useCount" => 0}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "createInviteCodes answers one group per forAccount", ctx do
    dids = [ctx.alice.did, did_for("bob")]
    body = codes(%{"codeCount" => 2, "useCount" => 1, "forAccounts" => dids}, ctx.token)

    assert [first, second] = body["codes"]
    assert first["account"] == Enum.at(dids, 0)
    assert second["account"] == Enum.at(dids, 1)
    assert length(first["codes"]) == 2
    assert length(second["codes"]) == 2
    assert Enum.all?(first["codes"], &(&1 not in second["codes"]))
  end

  test "a code creates one account and cannot be spent twice", ctx do
    code = sole_code(%{"codeCount" => 1, "useCount" => 1}, ctx.token)

    body = created_account(unique("bob"), code)

    assert body["active"]
    assert body["did"] == Did.did_for_username(:path_multi, host(), created_username(body))

    row = Repo.get_by(InviteCode, code: code)
    assert row.used_by == body["did"]
    assert row.used_at

    conn = post_account(unique("carol"), code)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidInviteCode"
  end

  test "a code with two uses creates two accounts and no third", ctx do
    code = sole_code(%{"codeCount" => 1, "useCount" => 2}, ctx.token)

    first = created_account(unique("bob"), code)
    second = created_account(unique("carol"), code)

    assert first["did"] != second["did"]

    assert %InviteCode{use_count: 2, uses: 2, used_by: did} = Repo.get_by(InviteCode, code: code)
    assert did == second["did"]

    conn = post_account(unique("dave"), code)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidInviteCode"
    assert %{uses: 2} = Repo.get_by(InviteCode, code: code)
  end

  test "a code for a DID is refused for any other account", ctx do
    code =
      sole_code(%{"codeCount" => 1, "useCount" => 1, "forAccounts" => [ctx.alice.did]}, ctx.token)

    assert %{uses: 0} = Repo.get_by(InviteCode, code: code)

    conn = post_account(unique("bob"), code)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidInviteCode"
    assert %{uses: 0} = Repo.get_by(InviteCode, code: code)
  end

  test "a code restricted to a DID it names still creates that account", ctx do
    username = unique("bob")

    code =
      sole_code(
        %{"codeCount" => 1, "useCount" => 1, "forAccounts" => [did_for(username)]},
        ctx.token
      )

    body = created_account(username, code)

    assert body["did"] == did_for(username)
  end

  test "a code no row names is refused" do
    conn = post_account(unique("bob"), "notacode")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidInviteCode"
  end

  test "a closed registration refuses an account with no code" do
    conn = post_account(unique("bob"), nil)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidInviteCode"
  end

  test "an open registration asks for no code", ctx do
    Application.put_env(:pesque, :registration, :open)

    conn = post_account(unique("bob"), nil)

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["active"]
    assert ctx.token
  end

  test "a code spent on an insert that then fails is spendable again", ctx do
    code = sole_code(%{"codeCount" => 1, "useCount" => 1}, ctx.token)

    taken = Repo.get_by(Accounts.User, did: ctx.alice.did)

    assert {:error, :email_taken} =
             Accounts.create_account(
               unique("bob") <> ".localhost",
               taken.email,
               @password,
               invite_code: code
             )

    assert %InviteCode{used_by: nil, used_at: nil, uses: 0} = Repo.get_by(InviteCode, code: code)
  end

  test "two accounts racing for one code yield one account", ctx do
    code = sole_code(%{"codeCount" => 1, "useCount" => 1}, ctx.token)

    results =
      [1, 2]
      |> Enum.map(fn i ->
        Task.async(fn ->
          Accounts.create_account(
            unique("racer") <> ".localhost",
            "#{i}-#{unique("mail")}@localhost",
            @password,
            invite_code: code
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_invite_code})) == 1
  end

  defp codes(params, token) do
    conn = xrpc_post(@path, params, token)
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp sole_code(params, token) do
    [group] = codes(params, token)["codes"]
    assert [code] = group["codes"]
    code
  end

  defp did_for(username), do: Did.did_for_username(:path_multi, host(), username)

  defp post_account(username, code) do
    params =
      %{
        "handle" => username <> ".localhost",
        "email" => username <> "@localhost",
        "password" => @password
      }
      |> then(fn p -> if code, do: Map.put(p, "inviteCode", code), else: p end)

    xrpc_post(@account_path, params, nil)
  end

  defp created_account(username, code) do
    conn = post_account(username, code)
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp created_username(%{"did" => did}), do: did |> String.split(":user:") |> List.last()
  defp host, do: Did.did_host(Pesque.hostname(), Pesque.port())

  defp put_registration(mode) do
    previous = Application.get_env(:pesque, :registration)

    on_exit(fn -> Application.put_env(:pesque, :registration, previous) end)

    Application.put_env(:pesque, :registration, mode)
    :ok
  end
end
