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

    # A field the lexicon does not declare is ignored rather than refused. The
    # specification classes an unexpected field as at worst a warning, and a
    # record type a newer lexicon added a field to has to keep validating
    # against the older copy held here. The cost is that a client-side typo in
    # a field name is stored unread rather than turned away.
    test "a field the object does not declare is ignored" do
      schema = %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

      assert :ok = Validate.validate(schema, %{"text" => "hi", "extra" => 1, "typo" => nil})
    end

    test "a declared field is still checked on an object with no required" do
      schema = %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

      assert {:error, [{["text"], :expected_string}]} = Validate.validate(schema, %{"text" => 1})
    end

    # nullable is a list of property names on the object, not a flag on the
    # property: the spec has no boolean form of it. A null there is a legal
    # value, and a null anywhere else is still handed to the type check.
    test "a nullable property takes null and a property outside the list does not" do
      schema =
        object(
          %{
            "note" => %{"type" => "string"},
            "count" => %{"type" => "integer"},
            "tag" => %{"type" => "string"}
          },
          []
        )
        |> Map.put("nullable", ["note", "count"])

      assert :ok = Validate.validate(schema, %{"note" => nil, "count" => nil, "tag" => "x"})
      assert :ok = Validate.validate(schema, %{"note" => "hi", "count" => 1})
      assert {:error, [{["tag"], :expected_string}]} = Validate.validate(schema, %{"tag" => nil})
    end

    test "a nullable property that is absent is still absent, not an error" do
      schema =
        object(%{"note" => %{"type" => "string"}}, [])
        |> Map.put("nullable", ["note"])

      assert :ok = Validate.validate(schema, %{})
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

    # An object with no properties is only reachable by a record lexicon whose
    # schema is empty, so what matters is that it does not crash and does not
    # invent a rule. The $type requirement belongs to unions, which is tested
    # there.
    test "an object with no properties accepts anything" do
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
    # The spec counts maxLength in UTF-8 bytes, so a value made of two byte
    # characters is over a limit of three even though a reader sees four
    # characters and String.length/1 reports four.
    test "maxLength counts UTF-8 bytes" do
      schema = %{"type" => "string", "maxLength" => 3}

      assert :ok = Validate.validate(schema, "abc")
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, "abcd")

      # Two bytes per character: four characters is eight bytes.
      two_byte = String.duplicate("é", 4)
      assert byte_size(two_byte) == 8
      assert String.length(two_byte) == 4
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, two_byte)

      # And the other way round: a four byte emoji fits under a limit of four.
      assert :ok = Validate.validate(%{"type" => "string", "maxLength" => 4}, <<0x1F600::utf8>>)
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, <<0x1F600::utf8>>)
    end

    # The byte bound is decided first, so an oversized value is refused without
    # the grapheme segmenter walking it.
    test "an over-long string is refused without also being counted in graphemes" do
      schema = %{"type" => "string", "maxLength" => 2, "maxGraphemes" => 1}

      assert {:error, [{[], :too_long}]} = Validate.validate(schema, "abcdef")
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

      # A $type naming no ref at all is refused once the union says closed,
      # which is what stops an AppView receiving a shape it cannot render.
      closed =
        object(%{"ref" => %{"type" => "union", "closed" => true, "refs" => ["#main"]}})

      bad = %{"ref" => %{"$type" => "#missing"}}
      assert {:error, [{["ref"], :unknown_type}]} = Validate.validate(closed, bad)

      # A ref carrying a #def suffix matches on the part before it.
      def2 = %{
        "type" => "object",
        "defs" => %{"link" => %{"type" => "object", "required" => ["uri"], "properties" => %{}}},
        "properties" => %{
          "ref" => %{"type" => "union", "closed" => true, "refs" => ["app.bsky.richtext.facet"]}
        }
      }

      assert :ok =
               Validate.validate(def2, %{"ref" => %{"$type" => "app.bsky.richtext.facet#link"}})

      assert {:error, [{["ref"], :unknown_type}]} =
               Validate.validate(def2, %{"ref" => %{"$type" => "app.bsky.other.thing"}})
    end

    # A union is open unless it opts in, because the spec has implementations
    # stay permissive in case they do not have the most recent lexicon. A union
    # with no refs and closed false is the "similar to unknown" case: all it
    # asks of a value is a $type.
    test "an open union takes a $type it does not list and a closed one does not" do
      open = object(%{"ref" => %{"type" => "union", "refs" => []}})
      closed = object(%{"ref" => %{"type" => "union", "closed" => true, "refs" => ["#main"]}})

      assert :ok = Validate.validate(open, %{"ref" => %{"$type" => "com.example.future"}})

      assert :ok =
               Validate.validate(open, %{"ref" => %{"$type" => "com.example.future", "x" => 1}})

      assert {:error, [{["ref"], :unknown_type}]} =
               Validate.validate(closed, %{"ref" => %{"$type" => "com.example.future"}})

      # The $type requirement holds either way: it is what a consumer
      # dispatches on, open or closed.
      assert {:error, [{["ref"], :missing_type}]} = Validate.validate(open, %{"ref" => %{}})
      assert {:error, [{["ref"], :missing_type}]} = Validate.validate(closed, %{"ref" => %{}})
    end

    # The member schema comes from the registry, keyed by the ref as the
    # lexicon wrote it. Without it a union body was unchecked: the $type named
    # an NSID and there was nothing to check the fields against.
    test "a member is checked against the schema the registry resolved for it" do
      schema = %{
        "type" => "union",
        "refs" => ["app.bsky.embed.images"],
        "variants" => %{
          "app.bsky.embed.images" => %{
            "type" => "object",
            "required" => ["images"],
            "properties" => %{"images" => %{"type" => "array", "items" => %{"type" => "string"}}}
          }
        }
      }

      assert :ok =
               Validate.validate(schema, %{
                 "$type" => "app.bsky.embed.images",
                 "images" => ["a"]
               })

      assert {:error, [{["images"], :expected_array}]} =
               Validate.validate(schema, %{"$type" => "app.bsky.embed.images", "images" => "nope"})

      assert {:error, [{["images"], :required}]} =
               Validate.validate(schema, %{"$type" => "app.bsky.embed.images"})

      assert {:error, [{["images", 0], :expected_string}]} =
               Validate.validate(schema, %{"$type" => "app.bsky.embed.images", "images" => [1]})
    end

    # A member this server holds no schema for is accepted on its name, which is
    # the same degradation an unresolvable ref gets anywhere else: a lexicon
    # referring to something absent must not refuse writes.
    test "a member with no resolved schema is accepted on its name" do
      schema = %{
        "type" => "object",
        "properties" => %{"ref" => %{"type" => "union", "refs" => ["com.nope.thing"]}}
      }

      assert :ok = Validate.validate(schema, %{"ref" => %{"$type" => "com.nope.thing"}})
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

    test "cid-link, token and unknown accept their parsed form" do
      for type <- ~w(cid-link token unknown) do
        assert :ok = Validate.validate(%{"type" => type}, "whatever")
        assert :ok = Validate.validate(%{"type" => type}, %Pesque.CID{})
      end
    end

    # $bytes arrives already decoded, so the length the lexicon states is
    # measurable rather than skipped.
    test "bytes is checked against maxLength" do
      schema = %{"type" => "bytes", "maxLength" => 4}

      assert :ok = Validate.validate(schema, "abcd")
      assert {:error, [{[], :too_long}]} = Validate.validate(schema, String.duplicate("a", 5))

      # And the raw form, which is what a record actually carries at validate
      # time, is measured on what it decodes to rather than on the base64.
      assert {:error, [{[], :too_long}]} =
               Validate.validate(schema, %{"$bytes" => Base.encode64(String.duplicate("a", 5))})

      assert :ok =
               Validate.validate(schema, %{"$bytes" => Base.encode64("abcd")})
    end

    # The size on a blob is the client's own claim: the bytes went to
    # uploadBlob and are not in the record to be measured. So this checks the
    # claim against what the lexicon allows, and uploadBlob is where the real
    # size is enforced.
    test "a blob is checked against maxSize and accept" do
      schema = %{"type" => "blob", "maxSize" => 10, "accept" => ["image/*"]}

      assert :ok = Validate.validate(schema, %{"size" => 10, "mimeType" => "image/jpeg"})

      assert {:error, [{[], :too_large}]} =
               Validate.validate(schema, %{"size" => 999_999_999, "mimeType" => "image/jpeg"})

      assert {:error, [{[], :bad_mime_type}]} =
               Validate.validate(schema, %{"size" => 1, "mimeType" => "text/html"})

      # An exact type and a wildcard subtype are both accepted, and a schema
      # stating no accept takes whatever mimeType arrives.
      exact = %{"type" => "blob", "accept" => ["image/png"]}
      assert :ok = Validate.validate(exact, %{"mimeType" => "image/png"})

      assert {:error, [{[], :bad_mime_type}]} =
               Validate.validate(exact, %{"mimeType" => "image/jpeg"})

      assert :ok = Validate.validate(%{"type" => "blob"}, %{"mimeType" => "text/html"})
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

    # The union body used to be unchecked: the $type named an NSID the validator
    # had no schema for, so every field under it was accepted. The lexicon
    # author and the submitter are independent parties, so this is the shape a
    # client sends to store whatever it likes under a post.
    test "a union body is checked against the member schema the registry resolved" do
      schema = Registry.record("app.bsky.feed.post")

      base = %{"text" => "hi", "createdAt" => "1985-04-12T23:20:50.123Z"}

      assert {:error, [{["embed", "images"], :expected_array}]} =
               Validate.validate(
                 schema,
                 Map.put(base, "embed", %{
                   "$type" => "app.bsky.embed.images",
                   "images" => "not an array at all"
                 })
               )

      # images is required by the real embed lexicon, so an embed that names the
      # type and carries nothing else is refused too.
      assert {:error, [{["embed", "images"], :required}]} =
               Validate.validate(
                 schema,
                 Map.put(base, "embed", %{"$type" => "app.bsky.embed.images"})
               )

      # And the labels union, which names a def of another lexicon: its values
      # array is required and its elements carry val.
      assert {:error, [{["labels", "values"], :expected_array}]} =
               Validate.validate(
                 schema,
                 Map.put(base, "labels", %{
                   "$type" => "com.atproto.label.defs#selfLabels",
                   "values" => %{"nope" => true}
                 })
               )
    end

    # A content warning is what the labels union is for, and it is a ref
    # carrying a fragment of someone else's lexicon: the declared ref is
    # "com.atproto.label.defs#selfLabels" and the value's $type is that same
    # string. Matching only the NSID before the "#" refused every one of them.
    test "a self-label round trips through the post lexicon" do
      schema = Registry.record("app.bsky.feed.post")

      post = %{
        "$type" => "app.bsky.feed.post",
        "text" => "hello",
        "createdAt" => "1985-04-12T23:20:50.123Z",
        "labels" => %{
          "$type" => "com.atproto.label.defs#selfLabels",
          "values" => [%{"val" => "!warn"}, %{"val" => "!hide"}]
        }
      }

      assert :ok = Validate.validate(schema, post)

      # And it is still checked: val is required on each label.
      assert {:error, [{["labels", "values", 0, "val"], :required}]} =
               Validate.validate(
                 schema,
                 put_in(post, ["labels", "values"], [%{}])
               )

      # And the ten-label cap the lexicon states is enforced.
      assert {:error, [{["labels", "values"], :too_long}]} =
               Validate.validate(
                 schema,
                 put_in(post, ["labels", "values"], List.duplicate(%{"val" => "!warn"}, 11))
               )
    end

    # The text the real post lexicon declares: 3000 bytes and 300 graphemes,
    # which are two different units and both have to hold.
    test "a post text over the byte cap is refused even when the grapheme count is fine" do
      schema = Registry.record("app.bsky.feed.post")

      base = %{"createdAt" => "1985-04-12T23:20:50.123Z"}

      # 300 graphemes, 6,000,300 bytes: String.length/1 reports one number for
      # all three units and byte_size/1 is the one the spec asks for.
      text = String.duplicate("a" <> String.duplicate(<<0x0301::utf8>>, 10_000), 300)
      assert byte_size(text) > 3000

      assert {:error, [{["text"], :too_long}]} =
               Validate.validate(schema, Map.put(base, "text", text))

      # 3000 bytes of four byte characters is 750 graphemes, which is over the
      # grapheme cap while under the byte one.
      under_bytes = String.duplicate(<<0x1F600::utf8>>, 750)
      assert byte_size(under_bytes) == 3000

      assert {:error, [{["text"], :too_many_graphemes}]} =
               Validate.validate(schema, Map.put(base, "text", under_bytes))
    end

    # site.standard.document declares its content union as closed false with no
    # refs at all, which the spec calls "similar to unknown": all it asks of the
    # value is a $type. Treating it as closed meant the collection could not
    # carry a content block whatsoever.
    test "an open union in a real lexicon takes a content block" do
      schema = Registry.record("site.standard.document")

      assert %{"closed" => false, "refs" => []} = schema["properties"]["content"]

      doc = %{
        "$type" => "site.standard.document",
        "site" => "https://example.com",
        "title" => "A post",
        "publishedAt" => "1985-04-12T23:20:50.123Z"
      }

      assert :ok =
               Validate.validate(
                 schema,
                 Map.put(doc, "content", %{"$type" => "app.bsky.richtext.richtextFacet"})
               )

      assert {:error, [{["content"], :missing_type}]} =
               Validate.validate(schema, Map.put(doc, "content", %{"text" => "hi"}))
    end

    # The cover is a blob with a maxSize and an accept list, and both are what
    # the lexicon states about it. The size is the client's claim, which is what
    # a record carries; uploadBlob is where the real size is enforced.
    test "a blob in a real lexicon is checked against its maxSize and accept" do
      schema = Registry.record("site.standard.document")

      doc = %{
        "$type" => "site.standard.document",
        "site" => "https://example.com",
        "title" => "A post",
        "publishedAt" => "1985-04-12T23:20:50.123Z",
        "coverImage" => %{
          "$type" => "blob",
          "ref" => %{"$link" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"},
          "mimeType" => "image/png",
          "size" => 5_000
        }
      }

      assert :ok = Validate.validate(schema, doc)

      assert {:error, errors} =
               Validate.validate(schema, put_in(doc, ["coverImage", "size"], 5_000_000))

      assert {["coverImage"], :too_large} in errors

      assert {:error, errors} =
               Validate.validate(schema, put_in(doc, ["coverImage", "mimeType"], "text/html"))

      assert {["coverImage"], :bad_mime_type} in errors
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
