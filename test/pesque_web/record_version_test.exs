defmodule PesqueWeb.RecordVersionTest do
  @moduledoc """
  getRecord with a cid asks for one version of a record rather than the
  latest one, which means the answer comes from the blocks table once the
  record has been written again, because the records table keeps only the
  latest.
  """

  use PesqueWeb.ConnCase, async: false

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "a cid answers with that version even after the record was updated", ctx do
    first = write(ctx.alice, ctx.token, "first")
    second = write(ctx.alice, ctx.token, "second")

    assert first["cid"] != second["cid"]

    assert read(ctx.alice, first["uri"], first["cid"])["value"]["text"] == "first"
    assert read(ctx.alice, second["uri"], second["cid"])["value"]["text"] == "second"
  end

  test "with no cid the latest version is answered", ctx do
    write(ctx.alice, ctx.token, "first")
    second = write(ctx.alice, ctx.token, "second")

    assert read(ctx.alice, second["uri"])["value"]["text"] == "second"
  end

  test "the uri answered is the one that was asked about", ctx do
    first = write(ctx.alice, ctx.token, "first")
    write(ctx.alice, ctx.token, "second")

    body = read(ctx.alice, first["uri"], first["cid"])

    assert body["uri"] == first["uri"]
    assert body["cid"] == first["cid"]
  end

  test "a cid this repo does not store is a missing record", ctx do
    uri = write(ctx.alice, ctx.token, "first")["uri"]

    conn =
      xrpc_get(
        query(ctx.alice.did, uri, "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a")
      )

    assert conn.status == 404
    assert JSON.decode!(conn.resp_body)["error"] == "RecordNotFound"
  end

  test "a cid stored under another account is not served out of this one", ctx do
    bob = create_account("bob")
    bobs = write(bob, token(bob), "bob's post")

    write(ctx.alice, ctx.token, "mine")

    conn = xrpc_get(query(ctx.alice.did, bobs["uri"], bobs["cid"]))

    assert conn.status == 404
    assert JSON.decode!(conn.resp_body)["error"] == "RecordNotFound"
  end

  defp write(user, token, text) do
    conn =
      xrpc_post(
        "/xrpc/com.atproto.repo.createRecord",
        %{"repo" => user.did, "collection" => collection(), "record" => post_record(text)},
        token
      )

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp read(user, uri, cid \\ nil) do
    conn = xrpc_get(query(user.did, uri, cid))

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp query(repo, uri, cid) do
    [collection, rkey] = uri |> String.split("/") |> Enum.take(-2)

    "/xrpc/com.atproto.repo.getRecord?repo=#{enc(repo)}" <>
      "&collection=#{enc(collection)}&rkey=#{enc(rkey)}" <>
      if cid, do: "&cid=#{enc(cid)}", else: ""
  end
end
