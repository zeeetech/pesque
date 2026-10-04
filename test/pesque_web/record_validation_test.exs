defmodule PesqueWeb.RecordValidationTest do
  @moduledoc """
  The write boundary with the lexicon in the way: what a record has to satisfy
  to be committed, and what a client is told when it does not.

  ConnTest because what is under test is the answer a client gets. A validator
  no request ever reaches is a module with no callers.
  """

  use PesqueWeb.ConnCase, async: false

  # No $type, which is the case the record module fills in.
  @post %{
    "text" => "hello",
    "createdAt" => "2026-01-01T00:00:00.000Z"
  }

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "a good post is stored and reported valid", ctx do
    conn = create_record(ctx, @post)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["validationStatus"] == "valid"

    assert stored(ctx, rkey(body))["text"] == "hello"
  end

  # The stored record carries the $type even though the request did not, since
  # a consumer reading it off the firehose has nothing to dispatch on without
  # one.
  test "the stored record carries the $type the request left out", ctx do
    conn = create_record(ctx, @post)
    assert conn.status == 200

    assert stored(ctx, rkey(JSON.decode!(conn.resp_body)))["$type"] == collection()
  end

  test "a record breaking the lexicon is a 400 naming the fields", ctx do
    conn = create_record(ctx, Map.put(@post, "createdAt", "last tuesday"))

    assert conn.status == 400

    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "InvalidRequest"
    assert body["message"] =~ "createdAt"

    assert RepoServer.entries(repo_pid(ctx)) == %{}
  end

  test "a record missing a required field is a 400", ctx do
    conn = create_record(ctx, Map.delete(@post, "text"))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["message"] =~ "text"
    assert RepoServer.entries(repo_pid(ctx)) == %{}
  end

  # A lexicon this server does not hold is not a statement about the record.
  # Saying so outright is what stops a client blaming its own data for a file
  # the operator has not installed.
  test "a collection this server holds no lexicon for is a 400", ctx do
    conn = create(ctx, %{"collection" => "com.example.unknown", "record" => %{}})

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert RepoServer.entries(repo_pid(ctx)) == %{}
  end

  # Caught before the fields, because a lexicon that does not declare the type
  # cannot say whether the rest was meant for this collection.
  test "a $type naming another collection is a 400", ctx do
    conn = create_record(ctx, Map.put(@post, "$type", "app.bsky.feed.like"))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["message"] =~ "app.bsky.feed.like"
  end

  test "validate false stores a record the lexicon would refuse and says unknown", ctx do
    conn = create(ctx, %{"record" => %{"text" => 42}, "validate" => false})

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["validationStatus"] == "unknown"
    assert stored(ctx, rkey(body))["text"] == 42
  end

  test "validate false stores a record in a collection no lexicon exists for", ctx do
    conn =
      create(ctx, %{
        "collection" => "com.example.unknown",
        "record" => %{},
        "validate" => false
      })

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["validationStatus"] == "unknown"
  end

  # Skipping validation does not skip the conversion, and the conversion is what
  # keeps an unencodable value from reaching the encoder, where a raise would
  # take the repo process down rather than answer.
  test "validate false still refuses a record DAG-CBOR cannot hold", ctx do
    conn =
      create(ctx, %{
        "validate" => false,
        "record" => %{"thing" => %{"$link" => "not-a-cid"}}
      })

    assert conn.status == 400
    assert RepoServer.entries(repo_pid(ctx)) == %{}
  end

  test "putRecord is checked the way createRecord is", ctx do
    params = %{"record" => Map.put(@post, "text", "updated"), "rkey" => "k"}

    assert write(ctx, "com.atproto.repo.putRecord", params).status == 200

    conn =
      write(ctx, "com.atproto.repo.putRecord", %{"record" => %{"text" => "raw"}, "rkey" => "k"})

    assert conn.status == 400
    assert stored(ctx, "k")["text"] == "updated"
  end

  defp create_record(ctx, record), do: create(ctx, %{"record" => record})

  defp create(ctx, params) do
    write(ctx, "com.atproto.repo.createRecord", Map.put_new(params, "record", @post))
  end

  defp write(ctx, method, params) do
    params =
      params
      |> Map.put_new("collection", collection())
      |> Map.put("repo", ctx.alice.did)

    xrpc_post("/xrpc/#{method}", params, ctx.token)
  end

  defp repo_pid(ctx) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(ctx.alice.did)
    pid
  end

  defp rkey(body), do: body["uri"] |> String.split("/") |> List.last()

  defp stored(ctx, rkey) do
    ("/xrpc/com.atproto.repo.getRecord?repo=#{enc(ctx.alice.did)}" <>
       "&collection=#{collection()}&rkey=#{enc(rkey)}")
    |> xrpc_get(ctx.token)
    |> Map.fetch!(:resp_body)
    |> JSON.decode!()
    |> Map.fetch!("value")
  end
end
