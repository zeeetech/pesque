defmodule Pesque.RecordTest do
  use ExUnit.Case, async: true

  alias Pesque.Record

  @post %{
    "$type" => "app.bsky.feed.post",
    "text" => "hello",
    "createdAt" => "2026-01-01T00:00:00.000Z"
  }

  test "a record matching its lexicon comes back with the $type the client sent" do
    post = @post

    assert {:ok, ^post} = Record.check("app.bsky.feed.post", post)
  end

  # The collection is the type, so a client that leaves it out has said what it
  # meant. The stored record has to say it too, or a consumer reading it off the
  # firehose has nothing to dispatch on.
  test "a record with no $type is given the collection" do
    record = Map.delete(@post, "$type")

    assert {:ok, stored} = Record.check("app.bsky.feed.post", record)
    assert stored["$type"] == "app.bsky.feed.post"
  end

  # app.bsky.actor.profile is the one record lexicon with no `required`, which
  # is the closed case, and no record lexicon declares $type as a property. So
  # a profile carrying the $type the protocol requires of it validates only
  # because the type is checked apart from the fields rather than among them.
  test "a closed record carrying a $type is not refused for it" do
    profile = %{"$type" => "app.bsky.actor.profile", "displayName" => "Alice"}

    assert {:ok, stored} = Record.check("app.bsky.actor.profile", profile)
    assert stored["displayName"] == "Alice"
  end

  test "a $type naming another collection is refused" do
    record = %{@post | "$type" => "app.bsky.feed.like"}

    assert {:error, {:type_mismatch, "app.bsky.feed.like", "app.bsky.feed.post"}} =
             Record.check("app.bsky.feed.post", record)
  end

  test "a record breaking the lexicon comes back with the paths that broke it" do
    assert {:error, {:invalid_record, errors}} =
             Record.check("app.bsky.feed.post", %{"text" => "hi", "createdAt" => "not a date"})

    assert {["createdAt"], {:bad_datetime, _, _}} =
             Enum.find(errors, &match?({["createdAt"], _}, &1))
  end

  test "a required field left out is refused" do
    assert {:error, {:invalid_record, [{["text"], :required}]}} =
             Record.check("app.bsky.feed.post", %{"createdAt" => "2026-01-01T00:00:00.000Z"})
  end

  test "a collection this server holds no lexicon for is refused" do
    assert {:error, :unknown_collection} = Record.check("com.example.nope", %{})
  end

  # A lexicon missing means this server cannot vouch for the record, not that
  # the record is bad. Refusing it would make the missing file the writer's
  # problem, which is the wrong way round.
  test "validate false stores a record no lexicon would accept" do
    record = %{"text" => 42, "nonsense" => true}

    assert {:ok, %{"$type" => "com.example.nope"}} =
             Record.check("com.example.nope", record, validate: false)

    assert {:ok, %{"$type" => "app.bsky.feed.post"}} =
             Record.check("app.bsky.feed.post", record, validate: false)
  end
end
