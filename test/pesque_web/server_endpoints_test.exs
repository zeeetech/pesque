defmodule PesqueWeb.ServerEndpointsTest do
  @moduledoc """
  The two endpoints a client needs before it can do anything at all:
  describeServer, which every app calls first, and checkAccountStatus, which an
  AppView calls before mirroring a repo.
  """

  use PesqueWeb.ConnCase, async: false

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "describeServer answers with this server's own did" do
    body = read("/xrpc/com.atproto.server.describeServer")

    assert body["did"] == Pesque.Identity.did()
    assert body["availableUserDomains"] == [Pesque.handle_domain()]
  end

  # Invite code required means an operator has to be involved in making an
  # account, which is exactly what a closed registration means here. Reporting
  # it the other way invites a client to send people who then get turned away.
  test "describeServer says an invite is needed when registration is closed" do
    assert read("/xrpc/com.atproto.server.describeServer")["inviteCodeRequired"]

    Application.put_env(:pesque, :registration, :open)

    refute read("/xrpc/com.atproto.server.describeServer")["inviteCodeRequired"]
  end

  test "describeServer needs no token" do
    assert xrpc_get("/xrpc/com.atproto.server.describeServer").status == 200
  end

  # A link a client cannot open is worse than no link, and a link to a
  # placeholder is worse still: the client shows it to a person as the server's
  # policy. This server has no policy of its own, so it advertises one only when
  # the operator set it.
  test "describeServer omits policy links until the operator sets them" do
    links = read("/xrpc/com.atproto.server.describeServer")["links"]

    refute Map.has_key?(links, "privacyPolicy")
    refute Map.has_key?(links, "termsOfService")
  end

  test "describeServer advertises the operator's policy documents" do
    Application.put_env(:pesque, :privacy_policy_url, "https://example.com/privacy")
    Application.put_env(:pesque, :terms_of_service_url, "https://example.com/terms")

    on_exit(fn ->
      Application.delete_env(:pesque, :privacy_policy_url)
      Application.delete_env(:pesque, :terms_of_service_url)
    end)

    links = read("/xrpc/com.atproto.server.describeServer")["links"]

    assert links["privacyPolicy"] == "https://example.com/privacy"
    assert links["termsOfService"] == "https://example.com/terms"
  end

  test "checkAccountStatus reports a repo that has been written to", ctx do
    params = %{
      "repo" => ctx.alice.did,
      "collection" => collection(),
      "record" => post_record("hello")
    }

    assert xrpc_post("/xrpc/com.atproto.repo.createRecord", params, ctx.token).status == 200

    body = status(ctx.alice.did)

    assert body["activated"]
    assert body["validDid"]
    assert body["repoBlocks"] > 0
    assert body["repoRev"]
    assert body["repoCommit"]
  end

  # An account nobody has written to is still an account. Answering 404 or
  # activated false would tell an AppView to drop a repo that exists.
  test "checkAccountStatus reports an account with no records as activated", ctx do
    body = status(ctx.alice.did)

    assert body["activated"]
    assert body["indexable"]

    # A repo has a commit from the moment the account exists, because the
    # genesis commit is written before the first record rather than on it. An
    # AppView that treated a missing commit as "not a repo yet" would drop
    # every account nobody had posted from.
    assert body["repoCommit"]
    assert body["repoRev"]
    assert body["repoBlocks"] > 0
  end

  test "checkAccountStatus answers for a handle as well as a did", ctx do
    assert status(ctx.alice.handle)["activated"]
  end

  test "checkAccountStatus says a repo this server does not host is not activated" do
    body = status("did:web:localhost%3A4000:user:nobody")

    refute body["activated"]
    refute body["indexable"]
    assert body["repoCommit"] == nil
  end

  test "checkAccountStatus needs a did" do
    conn = xrpc_get("/xrpc/com.atproto.server.checkAccountStatus")

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  defp read(path), do: xrpc_get(path) |> body()

  defp status(did) do
    read("/xrpc/com.atproto.server.checkAccountStatus?did=#{enc(did)}")
  end

  defp body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
