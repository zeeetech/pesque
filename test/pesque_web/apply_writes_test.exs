defmodule PesqueWeb.ApplyWritesTest do
  @moduledoc """
  applyWrites: a batch is one commit or none.

  ConnTest because every claim here is about what a client observes: the shape
  of the answer, and whether a rejected batch left anything behind.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query

  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event

  @path "/xrpc/com.atproto.repo.applyWrites"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "a batch of creates, an update and a delete lands as one commit", ctx do
    seed(ctx)

    before = RepoStore.max_seq()

    conn = apply_writes(ctx, %{"writes" => writes()}, ctx.token)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)

    assert %{"cid" => cid, "rev" => rev} = body["commit"]
    assert is_binary(cid)
    assert is_binary(rev)

    # One commit, so the event log grew by exactly one row past the seed.
    assert length(revisions_since(ctx, before)) == 1

    # Results come back in the order they were sent, each naming the record it
    # wrote.
    assert [created, generated, updated, deleted] = body["results"]

    # `results` is a closed union, so every entry names its member; a client
    # that validates the answer refuses one it cannot dispatch on.
    assert %{
             "$type" => "com.atproto.repo.applyWrites#createResult",
             "uri" => created_uri,
             "cid" => _,
             "validationStatus" => "valid"
           } = created

    assert created_uri == "at://#{ctx.alice.did}/#{collection()}/one"

    # A create with no rkey gets a generated one and answers with its uri.
    assert %{
             "$type" => "com.atproto.repo.applyWrites#createResult",
             "uri" => generated_uri,
             "cid" => _,
             "validationStatus" => "valid"
           } = generated

    assert String.starts_with?(generated_uri, "at://#{ctx.alice.did}/#{collection()}/")
    refute generated_uri == created_uri

    assert %{
             "$type" => "com.atproto.repo.applyWrites#updateResult",
             "uri" => updated_uri,
             "cid" => _,
             "validationStatus" => "valid"
           } = updated

    assert updated_uri == "at://#{ctx.alice.did}/#{collection()}/one"

    assert deleted == %{"$type" => "com.atproto.repo.applyWrites#deleteResult"}

    assert stored(ctx, "one")["text"] == "first updated"
    assert stored(ctx, "two")["text"] == "second"
    refute stored?(ctx, "doomed")
  end

  # The store is what a mirror reads, so a batch that half-applied would show
  # up here as records the answer never mentioned.
  test "every write in a batch is readable afterwards", ctx do
    seed(ctx)

    assert apply_writes(ctx, %{"writes" => writes()}, ctx.token).status == 200

    assert stored(ctx, "one")["text"] == "first updated"
    assert stored(ctx, "two")["text"] == "second"

    listed =
      xrpc_get(
        "/xrpc/com.atproto.repo.listRecords?repo=#{enc(ctx.alice.did)}&collection=#{collection()}"
      )
      |> Map.fetch!(:resp_body)
      |> JSON.decode!()

    assert length(listed["records"]) == 2
  end

  test "a batch is one commit, not one per write", ctx do
    seed(ctx)

    before = RepoStore.max_seq()

    assert apply_writes(ctx, %{"writes" => writes()}, ctx.token).status == 200

    assert [_one_event] = revisions_since(ctx, before)
  end

  # The point of the endpoint. A write that cannot land takes the whole batch
  # with it, and the answer says which one so a client can fix it rather than
  # guess.
  test "an invalid write rolls the whole batch back and names the write", ctx do
    seed(ctx)

    writes = [
      create("kept"),
      %{
        "$type" => "com.atproto.repo.applyWrites#update",
        "collection" => collection(),
        "rkey" => "missing",
        "value" => post_record("nope")
      },
      create("also-kept")
    ]

    conn = apply_writes(ctx, %{"writes" => writes}, ctx.token)

    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "RecordNotFound"
    assert body["message"] =~ "write 2"

    refute stored?(ctx, "kept")
    refute stored?(ctx, "also-kept")
    assert stored(ctx, "doomed")["text"] == "doomed"
  end

  test "a record breaking the lexicon rolls the batch back and names the field", ctx do
    writes = [
      create("kept"),
      create("bad", %{"text" => 42}),
      create("also-kept")
    ]

    conn = apply_writes(ctx, %{"writes" => writes}, ctx.token)

    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "InvalidRequest"
    assert body["message"] =~ "write 2"
    assert body["message"] =~ "text"

    refute stored?(ctx, "kept")
    refute stored?(ctx, "also-kept")
  end

  test "a batch that creates over an existing key is refused whole", ctx do
    seed(ctx)

    conn =
      apply_writes(ctx, %{"writes" => [create("doomed", %{"text" => "replaced"})]}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRecordKey"
    assert stored(ctx, "doomed")["text"] == "doomed"
  end

  test "an unknown write action is refused", ctx do
    conn =
      apply_writes(
        ctx,
        %{
          "writes" => [
            %{"$type" => "com.atproto.repo.applyWrites#patch", "collection" => collection()}
          ]
        },
        ctx.token
      )

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["message"] =~ "not supported"
  end

  # A malformed write is named and refused like any other, rather than taking
  # the request down on the way to the answer.
  test "a write missing a required field is a 400 naming the write", ctx do
    writes = [
      create("kept"),
      %{
        "$type" => "com.atproto.repo.applyWrites#create",
        "collection" => collection(),
        "rkey" => "novalue"
      }
    ]

    conn = apply_writes(ctx, %{"writes" => writes}, ctx.token)

    assert conn.status == 400
    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "InvalidRequest"
    assert body["message"] =~ "write 2"

    refute stored?(ctx, "kept")
  end

  # swapCommit is the optimistic concurrency check: a caller that read a head,
  # decided, and then wants to be sure nobody moved it in between. Comparing it
  # outside the write's own serialization would compare against a head that
  # could move before the commit, which is exactly what it exists to catch.
  test "a matching swapCommit applies the batch", ctx do
    seed(ctx)

    params = %{"swapCommit" => head(ctx), "writes" => [create("swapped", %{"text" => "swapped"})]}

    assert apply_writes(ctx, params, ctx.token).status == 200
    assert stored(ctx, "swapped")["text"] == "swapped"
  end

  test "a stale swapCommit answers InvalidSwap and writes nothing", ctx do
    seed(ctx)

    stale = head(ctx)
    assert apply_writes(ctx, %{"writes" => [create("moved-on")]}, ctx.token).status == 200

    params = %{
      "swapCommit" => stale,
      "writes" => [create("rejected"), create("also-rejected")]
    }

    conn = apply_writes(ctx, params, ctx.token)

    assert conn.status == 400
    assert %{"error" => "InvalidSwap"} = JSON.decode!(conn.resp_body)

    refute stored?(ctx, "rejected")
    refute stored?(ctx, "also-rejected")
  end

  test "validate false stores what the lexicon would refuse and answers unknown", ctx do
    writes = [
      %{
        "$type" => "com.atproto.repo.applyWrites#create",
        "collection" => collection(),
        "rkey" => "raw",
        "value" => %{"text" => 42}
      }
    ]

    conn = apply_writes(ctx, %{"validate" => false, "writes" => writes}, ctx.token)

    assert conn.status == 200
    assert [%{"validationStatus" => "unknown"}] = JSON.decode!(conn.resp_body)["results"]
    assert stored(ctx, "raw")["text"] == 42
  end

  test "a write to another account's repo is refused and changes nothing", ctx do
    bob = create_account("bob")
    seed_for(bob, token(bob))

    before = head_for(bob)

    conn = apply_writes(ctx, %{"repo" => bob.did, "writes" => [create("stolen")]}, ctx.token)

    assert conn.status == 400
    assert head_for(bob) == before
    refute stored?(for_account(bob, token(bob)), "stolen")
  end

  test "writes that are not an array are refused", ctx do
    conn = apply_writes(ctx, %{"writes" => "nope"}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "a missing writes array is refused", ctx do
    conn = apply_writes(ctx, %{}, ctx.token)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "applyWrites needs a token", ctx do
    conn = apply_writes(ctx, %{"writes" => [create("anon")]}, nil)

    assert conn.status == 401
    refute stored?(ctx, "anon")
  end

  # A create followed by a write to the same key inside one batch is what the
  # lexicon expects to work, and it only works if the batch sees its own
  # progress rather than the head it started from.
  test "a write inside a batch sees the writes before it in the same batch", ctx do
    writes = [
      create("chained", %{"text" => "first"}),
      %{
        "$type" => "com.atproto.repo.applyWrites#update",
        "collection" => collection(),
        "rkey" => "chained",
        "value" => post_record("second")
      },
      %{
        "$type" => "com.atproto.repo.applyWrites#delete",
        "collection" => collection(),
        "rkey" => "chained"
      }
    ]

    assert apply_writes(ctx, %{"writes" => writes}, ctx.token).status == 200
    refute stored?(ctx, "chained")
  end

  defp writes do
    [
      create("one", %{"text" => "first"}),
      create("two", %{"text" => "second"}),
      %{
        "$type" => "com.atproto.repo.applyWrites#update",
        "collection" => collection(),
        "rkey" => "one",
        "value" => post_record("first updated")
      },
      %{
        "$type" => "com.atproto.repo.applyWrites#delete",
        "collection" => collection(),
        "rkey" => "doomed"
      }
    ]
  end

  defp create(rkey, overrides \\ %{}),
    do: create(%{"text" => "hello"}, rkey, overrides)

  defp create(overrides, rkey, extra) do
    %{
      "$type" => "com.atproto.repo.applyWrites#create",
      "collection" => collection(),
      "rkey" => rkey,
      "value" => post_record("hello") |> Map.merge(overrides) |> Map.merge(extra)
    }
  end

  defp apply_writes(ctx, params, jwt) do
    xrpc_post(@path, Map.put_new(params, "repo", ctx.alice.did), jwt)
  end

  defp seed(ctx), do: seed_for(ctx.alice, ctx.token)

  defp seed_for(user, jwt) do
    params = %{
      "repo" => user.did,
      "collection" => collection(),
      "rkey" => "doomed",
      "record" => post_record("doomed")
    }

    assert xrpc_post("/xrpc/com.atproto.repo.createRecord", params, jwt).status == 200
    :ok
  end

  defp for_account(user, jwt) do
    %{alice: user, token: jwt}
  end

  defp head(ctx), do: head_for(ctx.alice)

  defp head_for(user), do: RepoStore.get_meta("commit:" <> user.did)

  # The revs in the event log are the commits, so counting them is what tells
  # one batch of three writes from three batches of one.
  defp revisions_since(ctx, before) do
    Repo.all(
      from e in Event,
        where: e.did == ^ctx.alice.did and e.seq > ^before,
        order_by: e.seq,
        select: e.seq
    )
  end

  defp fetch(ctx, rkey) do
    conn =
      xrpc_get(
        "/xrpc/com.atproto.repo.getRecord?repo=#{enc(ctx.alice.did)}&collection=#{collection()}&rkey=#{enc(rkey)}"
      )

    if conn.status == 200, do: {:ok, JSON.decode!(conn.resp_body)["value"]}, else: :error
  end

  defp stored?(ctx, rkey), do: fetch(ctx, rkey) != :error

  defp stored(ctx, rkey) do
    assert {:ok, value} = fetch(ctx, rkey)
    value
  end
end
