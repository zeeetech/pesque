defmodule Pesque.LexiconTest do
  use ExUnit.Case, async: true

  alias Pesque.{CBOR, CID, Lexicon}

  @link "bafyreiauu4dlrmesbnb7i24u7niyunmpxb6bg4dmpo7ul7wnslx5b77gf4"

  test "from_json turns a $link map into a CID" do
    assert Lexicon.from_json(%{"$link" => @link}) == CID.parse(@link)
  end

  test "from_json turns a $bytes map into a CBOR byte string" do
    assert Lexicon.from_json(%{"$bytes" => "aGVsbG8="}) == %CBOR.Bytes{data: "hello"}
  end

  test "from_json recurses through maps and lists" do
    json = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "reply" => %{"parent" => %{"$link" => @link}, "root" => %{"$link" => @link}},
      "embed" => %{"images" => [%{"$bytes" => "aGk="}]}
    }

    internal = Lexicon.from_json(json)

    assert internal["reply"]["parent"] == CID.parse(@link)
    assert internal["embed"]["images"] == [%CBOR.Bytes{data: "hi"}]
    assert internal["text"] == "hello"
  end

  test "from_json passes scalars through" do
    assert Lexicon.from_json("text") == "text"
    assert Lexicon.from_json(7) == 7
    assert Lexicon.from_json(nil) == nil
    assert Lexicon.from_json(true) == true
  end

  test "a $link key next to other keys is treated as a normal map" do
    json = %{"$link" => @link, "other" => 1}

    assert Lexicon.from_json(json) == %{"$link" => @link, "other" => 1}
  end

  test "to_json is the inverse of from_json" do
    json = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "reply" => %{"parent" => %{"$link" => @link}, "root" => %{"$link" => @link}},
      "embed" => %{"images" => [%{"$bytes" => "aGk="}]}
    }

    assert json |> Lexicon.from_json() |> Lexicon.to_json() == json
  end

  test "to_json passes scalars through" do
    assert Lexicon.to_json("text") == "text"
    assert Lexicon.to_json(7) == 7
    assert Lexicon.to_json(nil) == nil
  end
end
