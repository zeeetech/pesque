defmodule Pesque.LexiconTest do
  use ExUnit.Case, async: true

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Lexicon

  @link "bafyreiauu4dlrmesbnb7i24u7niyunmpxb6bg4dmpo7ul7wnslx5b77gf4"

  test "from_json turns a $link map into a CID" do
    assert Lexicon.from_json(%{"$link" => @link}) == {:ok, CID.parse(@link)}
  end

  test "from_json turns a $bytes map into a CBOR byte string" do
    assert Lexicon.from_json(%{"$bytes" => "aGVsbG8="}) == {:ok, %CBOR.Bytes{data: "hello"}}
  end

  test "from_json recurses through maps and lists" do
    json = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "reply" => %{"parent" => %{"$link" => @link}, "root" => %{"$link" => @link}},
      "embed" => %{"images" => [%{"$bytes" => "aGk="}]}
    }

    assert {:ok, internal} = Lexicon.from_json(json)

    assert internal["reply"]["parent"] == CID.parse(@link)
    assert internal["embed"]["images"] == [%CBOR.Bytes{data: "hi"}]
    assert internal["text"] == "hello"
  end

  test "from_json passes scalars through" do
    assert Lexicon.from_json("text") == {:ok, "text"}
    assert Lexicon.from_json(7) == {:ok, 7}
    assert Lexicon.from_json(nil) == {:ok, nil}
    assert Lexicon.from_json(true) == {:ok, true}
  end

  test "a $link key next to other keys is treated as a normal map" do
    json = %{"$link" => @link, "other" => 1}

    assert Lexicon.from_json(json) == {:ok, %{"$link" => @link, "other" => 1}}
  end

  # A record reaches from_json/1 as a map from a request, so a raise here
  # happens inside whichever process is holding the repo.
  test "a $link that does not parse aborts the conversion instead of raising" do
    for bad <- ["bafkrei", "b", "", "not a cid", "bafkre!", "bmfxxxxxxxx"] do
      assert Lexicon.from_json(%{"$link" => bad}) == {:error, :invalid_link}, bad
    end
  end

  test "a bad $link nested anywhere aborts the whole conversion" do
    json = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "embed" => %{
        "images" => [%{"$bytes" => "aGk="}],
        "record" => %{"$link" => "bafkrei"}
      }
    }

    assert Lexicon.from_json(json) == {:error, :invalid_link}
    assert Lexicon.from_json(%{"a" => [%{"$link" => "bafkrei"}]}) == {:error, :invalid_link}
  end

  test "a $bytes that is not base64 aborts the conversion instead of raising" do
    assert Lexicon.from_json(%{"$bytes" => "not base64!!"}) == {:error, :invalid_bytes}
    assert Lexicon.from_json(%{"$bytes" => "a"}) == {:error, :invalid_bytes}

    assert Lexicon.from_json(%{"embed" => %{"blob" => %{"$bytes" => "%%%"}}}) ==
             {:error, :invalid_bytes}
  end

  test "to_json is the inverse of from_json" do
    json = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "reply" => %{"parent" => %{"$link" => @link}, "root" => %{"$link" => @link}},
      "embed" => %{"images" => [%{"$bytes" => "aGk="}]}
    }

    assert {:ok, internal} = Lexicon.from_json(json)
    assert Lexicon.to_json(internal) == json
  end

  test "to_json passes scalars through" do
    assert Lexicon.to_json("text") == "text"
    assert Lexicon.to_json(7) == 7
    assert Lexicon.to_json(nil) == nil
    assert Lexicon.to_json(true) == true
  end
end
