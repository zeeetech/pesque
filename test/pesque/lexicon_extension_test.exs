defmodule Pesque.Lexicon.ExtensionTest do
  use ExUnit.Case, async: false

  alias Pesque.Lexicon.Registry
  alias Pesque.Lexicon.Validate

  setup do
    File.mkdir_p!(Registry.user_dir())
    Registry.reload()
    :ok
  end

  defp write(nsid, doc) do
    path = Path.join(Registry.user_dir(), nsid <> ".json")
    File.write!(path, JSON.encode!(doc))

    on_exit(fn ->
      File.rm(path)
      Registry.reload()
    end)

    Registry.reload()
    path
  end

  @note %{
    "type" => "record",
    "key" => "any",
    "record" => %{
      "type" => "object",
      "required" => ["note"],
      "properties" => %{
        "note" => %{"type" => "string", "maxLength" => 10},
        "count" => %{"type" => "integer", "minimum" => 1}
      }
    }
  }

  # The whole extension story: a file in data/lexicons, no config, no
  # registration call, and the collection validates like a built-in one.
  test "a lexicon dropped in data/lexicons is loaded and validates" do
    refute Registry.knows?("com.example.note")

    write("com.example.note", %{
      "lexicon" => 1,
      "id" => "com.example.note",
      "defs" => %{"main" => @note}
    })

    assert Registry.knows?("com.example.note")

    schema = Registry.record("com.example.note")

    assert :ok = Validate.validate(schema, %{"note" => "hi", "count" => 2})

    assert {:error, [{["note"], :too_long}]} =
             Validate.validate(schema, %{"note" => "far too long to fit"})

    assert {:error, [{["count"], :below_minimum}]} =
             Validate.validate(schema, %{"note" => "x", "count" => 0})
  end

  # A ref from a custom lexicon to a vendored one is the case a homelab hits
  # first: your own record pointing at a strongRef.
  test "a custom lexicon can ref a vendored one" do
    write("com.example.reply", %{
      "lexicon" => 1,
      "id" => "com.example.reply",
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "tid",
          "record" => %{
            "type" => "object",
            "required" => ["parent"],
            "properties" => %{
              "parent" => %{"type" => "ref", "ref" => "com.atproto.repo.strongRef"}
            }
          }
        }
      }
    })

    schema = Registry.record("com.example.reply")

    assert :ok =
             Validate.validate(schema, %{
               "parent" => %{
                 "uri" => "at://alice.example.com/app.bsky.feed.post/3jzfcijpj2z2a",
                 "cid" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
               }
             })

    assert {:error, [{["parent", "cid"], :bad_cid}]} =
             Validate.validate(schema, %{
               "parent" => %{
                 "uri" => "at://alice.example.com/app.bsky.feed.post/3jzfcijpj2z2a",
                 "cid" => "not-a-cid"
               }
             })
  end

  # A ref to a lexicon that is not installed must not refuse the write. The
  # cost is that subtree goes unchecked, which is the right side to fail on.
  test "a ref to a lexicon this server does not hold does not refuse the record" do
    write("com.example.dangling", %{
      "lexicon" => 1,
      "id" => "com.example.dangling",
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "tid",
          "record" => %{
            "type" => "object",
            "properties" => %{"other" => %{"type" => "ref", "ref" => "com.nope.thing"}}
          }
        }
      }
    })

    assert :ok = Validate.validate(Registry.record("com.example.dangling"), %{"other" => %{}})
  end

  # Two lexicons pointing at each other must terminate. Without the guard this
  # recurses until the VM runs out of stack, at boot, for anyone whose files
  # happen to point in a circle.
  test "a cycle between two custom lexicons terminates" do
    for nsid <- ["com.example.a", "com.example.b"] do
      write(nsid, %{
        "lexicon" => 1,
        "id" => nsid,
        "defs" => %{
          "main" => %{
            "type" => "record",
            "key" => "tid",
            "record" => %{
              "type" => "object",
              "properties" => %{"next" => %{"type" => "ref", "ref" => other(nsid)}}
            }
          }
        }
      })
    end

    assert Registry.record("com.example.a")
    assert Registry.record("com.example.b")
  end

  # Resolving a union's members walks the ref graph too, so a union whose
  # member is the lexicon holding it has to terminate for the same reason the
  # two-lexicon cycle above does.
  test "a union whose member points back at its own lexicon terminates" do
    write("com.example.selfref", %{
      "lexicon" => 1,
      "id" => "com.example.selfref",
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "tid",
          "record" => %{
            "type" => "object",
            "required" => ["body"],
            "properties" => %{
              "body" => %{"type" => "union", "refs" => ["com.example.selfref"]}
            }
          }
        }
      }
    })

    assert %{"properties" => %{"body" => body}} = Registry.record("com.example.selfref")
    assert body["type"] == "union"

    # The member resolves once and then stops: the cycle guard leaves the second
    # pass with nothing to look up, rather than resolving forever.
    assert Map.keys(body["variants"]) == ["com.example.selfref"]
  end

  defp other("com.example.a"), do: "com.example.b"
  defp other("com.example.b"), do: "com.example.a"

  # One broken file is a warning, not a boot failure. A server that was up has
  # to stay up.
  test "a file that is not a lexicon is skipped rather than raised on" do
    path = Path.join(Registry.user_dir(), "broken.json")
    File.write!(path, "{not json")

    on_exit(fn ->
      File.rm(path)
      Registry.reload()
    end)

    assert Registry.reload() == :ok
    assert Registry.knows?("app.bsky.feed.post")
  end

  test "a file with no id is skipped" do
    path = Path.join(Registry.user_dir(), "anonymous.json")
    File.write!(path, JSON.encode!(%{"lexicon" => 1, "defs" => %{}}))

    on_exit(fn ->
      File.rm(path)
      Registry.reload()
    end)

    assert Registry.reload() == :ok
    assert map_size(Registry.all()) >= 400
  end

  # The override path: a copy in data/lexicons wins over the vendored file,
  # which is what makes patching a lexicon an edit rather than a fork.
  test "a custom copy replaces a vendored lexicon of the same id" do
    original = Registry.get("app.bsky.feed.post")

    write("app.bsky.feed.post", %{
      "lexicon" => 1,
      "id" => "app.bsky.feed.post",
      "defs" => %{
        "main" => %{
          "type" => "record",
          "key" => "tid",
          "record" => %{
            "type" => "object",
            "required" => ["note"],
            "properties" => %{"note" => %{"type" => "string"}}
          }
        }
      }
    })

    patched = Registry.record("app.bsky.feed.post")

    assert patched["required"] == ["note"]
    refute patched == Registry.record("app.bsky.feed.post.notreal")

    # And it is still in the vendored tree, untouched, so a sync restores it.
    assert File.exists?(Path.join(Registry.vendored_dir(), "app/bsky/feed/post.json"))

    assert original["id"] == "app.bsky.feed.post"
  end
end
