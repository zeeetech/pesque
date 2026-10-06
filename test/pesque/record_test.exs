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

  # app.bsky.actor.profile declares no required fields, so before undeclared
  # fields stopped being refused it was the one record type a $type could be
  # turned away for. It does not need that any more: the record is validated as
  # submitted and a field the lexicon does not name is ignored.
  test "a record carrying a $type the lexicon does not declare is not refused for it" do
    profile = %{"$type" => "app.bsky.actor.profile", "displayName" => "Alice"}

    assert {:ok, stored} = Record.check("app.bsky.actor.profile", profile)
    assert stored["displayName"] == "Alice"
    assert stored["$type"] == "app.bsky.actor.profile"
  end

  # A null $type is not an absent one. The spec says a record object always
  # carries its type, and a stored null is a value with nothing to dispatch on
  # and nothing that can ever validate it.
  test "a $type of null is refused rather than stored" do
    record = Map.put(@post, "$type", nil)

    assert {:error, {:invalid_record, [{["$type"], :missing_type}]}} =
             Record.check("app.bsky.feed.post", record)
  end

  # And the stored record always carries the collection, whatever the client
  # sent, so a consumer reading it off the firehose has the one value to
  # dispatch on.
  test "the stored record carries the collection even when validation is off" do
    record = %{"text" => "hi", "$type" => nil}

    assert {:ok, %{"$type" => "app.bsky.feed.post"}} =
             Record.check("app.bsky.feed.post", record, validate: false)
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
