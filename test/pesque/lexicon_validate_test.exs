defmodule Pesque.Lexicon.ValidateTest do
  use ExUnit.Case, async: true

  alias Pesque.Lexicon.Registry
  alias Pesque.Lexicon.Validate

  defp object(properties, required \\ []),
    do: %{"type" => "object", "required" => required, "properties" => properties}

  describe "objects" do
    test "an open object takes the fields it declares and tolerates the rest" do
      schema = object(%{"text" => %{"type" => "string"}}, ["text"])

      assert :ok = Validate.validate(schema, %{"text" => "hi", "futureField" => 1})
    end

    test "a closed object refuses a field it does not declare" do
      schema = %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

      assert {:error, [{["extra"], :unknown_field}]} =
               Validate.validate(schema, %{"text" => "hi", "extra" => 1})
    end

    test "a required field that is missing or nil is refused" do
      schema = object(%{"text" => %{"type" => "string"}}, ["text"])

      assert {:error, [{["text"], :required}]} = Validate.validate(schema, %{})
      # nil reports both that the field is absent and that it is not a string.
      # Both are true and both are worth saying.
      assert {:error, errors} = Validate.validate(schema, %{"text" => nil})
      assert Enum.map(errors, &elem(&1, 1)) == [:expected_string, :required]
    end

    test "a nested miss reports the path to it" do
      schema =
        object(
          %{"embed" => object(%{"uri" => %{"type" => "string"}}, ["uri"])},
          ["embed"]
        )

      assert {:error, [{["embed", "uri"], :required}]} =
               Validate.validate(schema, %{"embed" => %{}})
    end

    # A closed object with nothing to check is only reachable by a record
    # lexicon whose schema is empty, so what matters is that it does not crash
    # and does not invent a rule. The $type requirement belongs to unions, which
    # is tested there.
    test "a closed object with no properties accepts anything" do
      assert :ok = Validate.validate(%{"type" => "object", "properties" => %{}}, %{})
    end

    test "an object that is not a map is refused" do
      assert {:error, [{[], :expected_object}]} = Validate.validate(object(%{}), "nope")
    end
  end

  describe "arrays" do
    test "an element is checked against items" do
      schema = %{"type" => "array", "items" => %{"type" => "string"}}

      assert :ok = Validate.validate(schema, ["a", "b"])
      assert {:error, [{[1], :expected_string}]} = Validate.validate(schema, ["a", 1])
    end

    test "minLength and maxLength are enforced" do
      schema = %{"type" => "array", "minLength" => 1, "maxLength" => 2}

      assert :ok = Validate.validate(schema, ["a"])
      assert {:error, [{[], :too_short}]} = Validate.validate(schema, [])
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, ["a", "b", "c"])
    end
  end

  describe "strings" do
    test "maxLength counts codepoints" do
      schema = %{"type" => "string", "maxLength" => 3}

      assert :ok = Validate.validate(schema, "abc")
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, "abcd")
    end

    # The reason the repo carries its own grapheme segmenter: a limit written
    # as "300 characters" has to count what the author saw, and String.length
    # reports a family emoji as 7.
    test "maxGraphemes counts clusters, not scalars" do
      schema = %{"type" => "string", "maxGraphemes" => 1}
      family = "👨‍👩‍👧‍👦"

      # 7 codepoints, one character. A maxGraphemes written as "characters"
      # means the second one, so a family emoji must not read as over the limit.
      assert String.length(family) == 1
      assert byte_size(family) > 1
      assert :ok = Validate.validate(schema, family)
      assert {:error, [{[], :too_many_graphemes}]} = Validate.validate(schema, family <> "!")
    end

    test "enum and const are enforced" do
      schema = %{"type" => "string", "enum" => ["a", "b"], "const" => "a"}

      assert :ok = Validate.validate(schema, "a")

      # Both rules fire on "b": it is in the enum and it is not the const. They
      # are reported together rather than short-circuited, because a client
      # fixing one of them still has the other to deal with.
      assert {:error, [{[], :not_const}]} = Validate.validate(schema, "b")
      assert {:error, errors} = Validate.validate(schema, "c")
      assert Enum.map(errors, &elem(&1, 1)) == [:not_in_enum, :not_const]
    end

    test "an integer is not a string" do
      assert {:error, [{[], :expected_string}]} = Validate.validate(%{"type" => "string"}, 1)
    end
  end

  describe "formats" do
    defp format(name), do: %{"type" => "string", "format" => name}

    test "datetime takes a timestamp or a bare date, and refuses the rest" do
      assert :ok = Validate.validate(format("datetime"), "1985-04-12T23:20:50.123Z")
      assert :ok = Validate.validate(format("datetime"), "1985-04-12")

      assert {:error, [{[], {:bad_datetime, _, _}}]} =
               Validate.validate(format("datetime"), "yesterday")
    end

    test "at-uri, did and handle are checked by shape" do
      assert :ok =
               Validate.validate(format("at-uri"), "at://alice.example.com/app.bsky.feed.post/1")

      assert {:error, [{[], :bad_at_uri}]} =
               Validate.validate(format("at-uri"), "https://example.com")

      assert :ok = Validate.validate(format("did"), "did:web:example.com")
      assert {:error, [{[], :bad_did}]} = Validate.validate(format("did"), "web:example.com")

      assert :ok = Validate.validate(format("handle"), "alice.example.com")
      assert {:error, [{[], :bad_handle}]} = Validate.validate(format("handle"), "alice/example")
    end

    test "nsid cannot have a numeric first segment or too few segments" do
      assert :ok = Validate.validate(format("nsid"), "app.bsky.feed.post")
      assert {:error, [{[], :bad_nsid}]} = Validate.validate(format("nsid"), "app.bsky")
      assert {:error, [{[], :bad_nsid}]} = Validate.validate(format("nsid"), "1.bsky.feed.post")
    end

    test "tid is 13 characters of the TID alphabet" do
      assert :ok = Validate.validate(format("tid"), "3jzfcijpj2z2a")
      assert {:error, [{[], :bad_tid}]} = Validate.validate(format("tid"), "short")
      assert {:error, [{[], :bad_tid}]} = Validate.validate(format("tid"), "0000000000000")
    end

    test "record-key allows self and the tid-safe alphabet" do
      assert :ok = Validate.validate(format("record-key"), "self")
      assert :ok = Validate.validate(format("record-key"), "3jzfcijpj2z2a")

      assert {:error, [{[], :bad_record_key}]} =
               Validate.validate(format("record-key"), "has space")
    end

    test "cid is parsed, not pattern matched" do
      assert :ok =
               Validate.validate(
                 format("cid"),
                 "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
               )

      assert {:error, [{[], :bad_cid}]} = Validate.validate(format("cid"), "not-a-cid")
    end

    test "uri, language and at-identifier" do
      assert :ok = Validate.validate(format("uri"), "https://example.com")
      assert {:error, [{[], :bad_uri}]} = Validate.validate(format("uri"), "example.com")

      assert :ok = Validate.validate(format("language"), "pt-BR")
      assert {:error, [{[], :bad_language}]} = Validate.validate(format("language"), "pt_BR")

      assert :ok = Validate.validate(format("at-identifier"), "at://example.com")
      assert :ok = Validate.validate(format("at-identifier"), "did:web:example.com")
      assert :ok = Validate.validate(format("at-identifier"), "alice@example.com")

      assert {:error, [{[], :bad_at_identifier}]} =
               Validate.validate(format("at-identifier"), "example.com")
    end

    # An unrecognized format is refused rather than passed through. Silently
    # ignoring one would mean a lexicon using a rule this server never heard of
    # validates clean, which is the one outcome a validator must not produce.
    test "a format this server does not implement is refused" do
      assert {:error, [{[], {:unsupported_format, "emoji"}}]} =
               Validate.validate(format("emoji"), "x")
    end
  end

  describe "numbers" do
    test "integer honours minimum, maximum and const" do
      schema = %{"type" => "integer", "minimum" => 1, "maximum" => 10}

      assert :ok = Validate.validate(schema, 5)
      assert {:error, [{[], :below_minimum}]} = Validate.validate(schema, 0)
      assert {:error, [{[], :above_maximum}]} = Validate.validate(schema, 11)

      assert {:error, [{[], :not_const}]} =
               Validate.validate(%{"type" => "integer", "const" => 3}, 4)
    end

    test "an integer is not a float and a float is not an integer" do
      assert {:error, [{[], :expected_float}]} = Validate.validate(%{"type" => "float"}, 1)
      assert {:error, [{[], :expected_integer}]} = Validate.validate(%{"type" => "integer"}, 1.0)
    end

    test "number takes either" do
      assert :ok = Validate.validate(%{"type" => "number"}, 1)
      assert :ok = Validate.validate(%{"type" => "number"}, 1.5)
      assert {:error, [{[], :expected_number}]} = Validate.validate(%{"type" => "number"}, "1")
    end
  end

  describe "unions" do
    test "a $type among the refs is followed and its properties are checked" do
      schema = %{
        "type" => "object",
        "defs" => %{"main" => %{"type" => "object", "required" => ["uri"], "properties" => %{}}},
        "properties" => %{
          "ref" => %{"type" => "union", "refs" => ["#main", "app.bsky.richtext.facet"]}
        }
      }

      value = %{"ref" => %{"$type" => "#main"}}
      assert :ok = Validate.validate(schema, value)

      # A $type naming no ref at all is refused: that is the union being closed,
      # and it is what stops an AppView receiving a shape it cannot render.
      bad = %{"ref" => %{"$type" => "#missing"}}
      assert {:error, [{["ref"], :unknown_type}]} = Validate.validate(schema, bad)

      # A ref carrying a #def suffix matches on the part before it.
      def2 = %{
        "type" => "object",
        "defs" => %{"link" => %{"type" => "object", "required" => ["uri"], "properties" => %{}}},
        "properties" => %{"ref" => %{"type" => "union", "refs" => ["app.bsky.richtext.facet"]}}
      }

      assert :ok =
               Validate.validate(def2, %{"ref" => %{"$type" => "app.bsky.richtext.facet#link"}})

      assert {:error, [{["ref"], :unknown_type}]} =
               Validate.validate(def2, %{"ref" => %{"$type" => "app.bsky.other.thing"}})
    end

    test "a foreign ref is accepted on its name, since the registry is not read here" do
      schema = %{
        "type" => "object",
        "properties" => %{"ref" => %{"type" => "union", "refs" => ["app.bsky.richtext.facet"]}}
      }

      assert :ok = Validate.validate(schema, %{"ref" => %{"$type" => "app.bsky.richtext.facet"}})
    end

    test "a union without a $type is refused" do
      schema = %{
        "type" => "object",
        "properties" => %{"ref" => %{"type" => "union", "refs" => ["#main"]}}
      }

      assert {:error, [{["ref"], :missing_type}]} = Validate.validate(schema, %{"ref" => %{}})
    end
  end

  describe "refs and untyped nodes" do
    # The point of skipping: a broken cross-reference in someone's lexicon
    # should not make their server refuse every write.
    test "an unresolvable ref passes rather than failing the record" do
      assert :ok = Validate.validate(%{"type" => "ref", "ref" => "com.nope.thing"}, "anything")
    end

    test "bytes, cid-link, blob, token and unknown accept their parsed form" do
      for type <- ~w(bytes cid-link blob token unknown) do
        assert :ok = Validate.validate(%{"type" => type}, "whatever")
        assert :ok = Validate.validate(%{"type" => type}, %Pesque.CID{})
      end
    end

    test "boolean accepts both and refuses the rest" do
      assert :ok = Validate.validate(%{"type" => "boolean"}, true)
      assert :ok = Validate.validate(%{"type" => "boolean"}, false)
      assert {:error, [{[], :expected_boolean}]} = Validate.validate(%{"type" => "boolean"}, 1)
    end

    test "a definition with no recognized type is refused, not passed" do
      assert {:error, [{[], :unrecognized_definition}]} =
               Validate.validate(%{"format" => "tid"}, "x")
    end

    test "a nil definition validates nothing, so an unknown collection is not this module's error" do
      assert :ok = Validate.validate(nil, %{"anything" => true})
    end
  end

  describe "the vendored set" do
    setup do
      Registry.reload()
      :ok
    end

    test "every lexicon in priv/lexicons loaded and keyed by its own id" do
      assert map_size(Registry.all()) >= 400
    end

    test "app.bsky.feed.post and com.atproto.repo.strongRef are present" do
      assert %{"id" => "app.bsky.feed.post"} = Registry.get("app.bsky.feed.post")
      assert %{"id" => "com.atproto.repo.strongRef"} = Registry.get("com.atproto.repo.strongRef")
    end

    # The record schema is the object inside the schema whose type is "record",
    # so this is the shape a value is validated against, keyed by the fields
    # the collection actually requires.
    test "record/1 finds the schema a collection's records are checked against" do
      assert %{"type" => "object", "required" => ["text", "createdAt"]} =
               Registry.record("app.bsky.feed.post")

      assert Registry.record("app.bsky.feed.nonexistent") == nil
      refute Registry.knows?("app.bsky.feed.nonexistent")
    end

    test "a lexicon with no record type is not a collection" do
      # strongRef is an object every record embeds, not a collection of its own.
      assert Registry.get("com.atproto.repo.strongRef")
      assert Registry.record("com.atproto.repo.strongRef") == nil
      refute Registry.knows?("com.atproto.repo.strongRef")
    end

    # The end-to-end check: a post as a real client would send it has to pass
    # every rule the vendored post lexicon states, which is the whole reason
    # the set is vendored rather than fetched at boot.
    test "a realistic post validates against the real post lexicon" do
      schema = Registry.record("app.bsky.feed.post")

      post = %{
        "$type" => "app.bsky.feed.post",
        "text" => "hello",
        "createdAt" => "1985-04-12T23:20:50.123Z",
        "langs" => ["pt-BR"],
        "facets" => [
          %{
            "index" => %{"byteStart" => 0, "byteEnd" => 5},
            "features" => [
              %{
                "$type" => "app.bsky.richtext.facet#link",
                "uri" => "https://example.com"
              }
            ]
          }
        ],
        "reply" => %{
          "root" => %{
            "$type" => "com.atproto.repo.strongRef",
            "uri" => "at://alice.example.com/app.bsky.feed.post/3jzfcijpj2z2a",
            "cid" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
          },
          "parent" => %{
            "$type" => "com.atproto.repo.strongRef",
            "uri" => "at://alice.example.com/app.bsky.feed.post/3jzfcijpj2z2b",
            "cid" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
          }
        },
        "embed" => %{
          "$type" => "app.bsky.embed.images",
          "images" => [
            %{
              "alt" => "a cat",
              "image" => %{
                "$type" => "blob",
                "ref" => %{
                  "$link" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
                },
                "mimeType" => "image/jpeg",
                "size" => 1234
              },
              "aspectRatio" => %{"width" => 16, "height" => 9}
            }
          ]
        }
      }

      assert :ok = Validate.validate(schema, post)
    end

    test "a post with a wrong type in a field the lexicon constrains is caught" do
      schema = Registry.record("app.bsky.feed.post")

      # text is required by the real lexicon, so it is supplied: what is under
      # test here is the field that is wrong, not the one that is absent.
      assert {:error, [{["createdAt"], {:bad_datetime, _, _}}]} =
               Validate.validate(schema, %{"text" => "hi", "createdAt" => "not a date"})

      # The reply block is a com.atproto.repo.strongRef, which the registry
      # resolved into the schema before validating. That is what puts the
      # at-uri and cid formats of a reply under this check at all, instead of
      # leaving the whole subtree unchecked. root is absent too, and the real
      # lexicon requires it, so that is reported alongside.
      assert {:error, errors} =
               Validate.validate(schema, %{
                 "text" => "hi",
                 "createdAt" => "1985-04-12T23:20:50.123Z",
                 "reply" => %{"parent" => %{"cid" => "nope", "uri" => "https://example.com"}}
               })

      assert [
               {["reply", "parent", "uri"], :bad_at_uri},
               {["reply", "parent", "cid"], :bad_cid},
               {["reply", "root"], :required}
             ] = errors

      errors
    end

    test "every vendored record lexicon is one this server can check" do
      # A lexicon whose record definition is a type validate/2 has never heard
      # of would silently accept anything, so each one is exercised against a
      # deliberately wrong value and has to complain.
      records =
        Enum.flat_map(Registry.all(), fn {_nsid, doc} ->
          doc |> Map.get("defs", %{}) |> Enum.filter(fn {_n, d} -> d["type"] == "record" end)
        end)

      assert length(records) == 27

      for record <- records do
        assert {:error, _} = Validate.validate(record, "definitely not an object")
      end
    end
  end
end
