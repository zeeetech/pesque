defmodule PesqueWeb.AtprotoDidTest do
  @moduledoc """
  What an external client sees when it resolves one of this server's handles
  over HTTPS.

  The DNS method is the one this server cannot influence, so this file covers
  the half it does serve: `https://<handle>/.well-known/atproto-did` answering
  the DID that handle belongs to, as `text/plain` with no wrapper.
  """

  use PesqueWeb.ConnCase, async: false

  setup do
    alice = create_account("alice")

    %{alice: alice}
  end

  test "the well-known answer is the did of the handle it was reached under", ctx do
    conn = atproto_did(ctx.alice.handle)

    assert conn.status == 200
    assert conn.resp_body == ctx.alice.did
  end

  test "the body is bare text/plain with no wrapper", ctx do
    conn = atproto_did(ctx.alice.handle)

    assert ["text/plain" <> _rest] = get_resp_header(conn, "content-type")

    # The spec says the body is the DID and nothing else. A JSON document or a
    # trailing newline here is a body a client cannot parse.
    assert conn.resp_body == String.trim(conn.resp_body)
    refute String.contains?(conn.resp_body, "{")
  end

  test "each hosted handle answers with its own did", ctx do
    bob = create_account("bob")

    refute ctx.alice.did == bob.did
    assert atproto_did(ctx.alice.handle).resp_body == ctx.alice.did
    assert atproto_did(bob.handle).resp_body == bob.did
  end

  test "a name this server does not host is a 404" do
    assert atproto_did("alice.elsewhere.example").status == 404
    assert atproto_did("alice.localhost.evil.com").status == 404
  end

  test "a handle nobody has claimed is a 404" do
    assert atproto_did("nobody.localhost").status == 404
  end

  test "the bare handle domain answers for the single account under conformant_single" do
    put_mode(:conformant_single)

    conn = atproto_did(Pesque.handle_domain())

    assert conn.status == 200
    assert conn.resp_body == Pesque.Identity.did()
  end

  # The spec requires the link to work in both directions, and the DID document
  # is where the claim is published. A well-known answer the account's own
  # document does not corroborate resolves to nothing, whatever the endpoint
  # said.
  test "the served did and the served document agree on the handle", ctx do
    assert atproto_did(ctx.alice.handle).resp_body == ctx.alice.did

    {:ok, document} = Pesque.Accounts.did_document_for(ctx.alice)

    assert document["alsoKnownAs"] == ["at://" <> ctx.alice.handle]
  end

  # The DID is minted once, at account creation, and a handle change does not
  # move it. Answering with a re-derived DID here would resolve the handle to
  # an account that has no row, so the stored one is what has to come back.
  # The DID is minted once, at account creation, and a handle change does not
  # move it. Answering with a re-derived DID here would resolve the handle to
  # an account that has no row, so the stored one is what has to come back.
  test "a handle that moves answers with the did it was created with" do
    account = create_account("mover")
    original = account.handle
    fresh = unique("fresh") <> ".localhost"

    {:ok, moved} = Pesque.Accounts.update_handle(account, fresh)

    assert moved.handle == fresh
    assert moved.did == account.did
    assert atproto_did(fresh).resp_body == account.did
    assert atproto_did(original).status == 404
  end

  defp atproto_did(host) do
    # conn.host is what the controller reads, and Plug keeps it in step with
    # the host header, so the header cannot be set independently of it.
    %Plug.Conn{build_conn() | host: host}
    |> dispatch(PesqueWeb.Endpoint, :get, "/.well-known/atproto-did", nil)
  end
end
