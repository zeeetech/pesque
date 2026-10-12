defmodule Pesque.OAuth.PermissionSetsTest do
  @moduledoc """
  Permission sets: what a set expands to, what it may name, what the consent
  page calls it, and the order its resolution asks its sources in.

  The expansion half is pure and is answered against the real vendored sets -
  `app.bsky.authFullApp` and `chat.bsky.authFullChatClient` are the two
  documents a real client asks for - beside synthetic ones for the rules the
  vendored sets do not exercise. Resolution is the one shared cache table and
  the one swappable aggregator, so this file is not async: the application
  env the seam reads is moved only while nothing else can read it mid-swap.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pesque.Lexicon.Registry
  alias Pesque.OAuth.Grants
  alias Pesque.OAuth.Permission
  alias Pesque.OAuth.PermissionSets
  alias Pesque.OAuth.PermissionSets.Cache

  @appview "did:web:api.bsky.app#appview"

  defmodule FakeAggregator do
    @moduledoc "The aggregator a test stands in for: answers it was given, nothing else."

    @behaviour Pesque.Lexicon.Resolver

    def resolve(nsid) do
      answers = :persistent_term.get(:permission_sets_fake_answers, %{})
      calls = :persistent_term.get(:permission_sets_fake_calls, %{})

      :persistent_term.put(:permission_sets_fake_calls, Map.update(calls, nsid, 1, &(&1 + 1)))

      Map.get(answers, nsid, {:error, :not_found})
    end
  end

  setup do
    Application.put_env(:pesque, :lexicon_resolver, FakeAggregator)
    :persistent_term.put(:permission_sets_fake_answers, %{})
    :persistent_term.put(:permission_sets_fake_calls, %{})

    on_exit(fn ->
      Application.delete_env(:pesque, :lexicon_resolver)
      :persistent_term.erase(:permission_sets_fake_answers)
      :persistent_term.erase(:permission_sets_fake_calls)
    end)

    :ok
  end

  describe "expand" do
    test "the vendored full-app set inherits the include's audience" do
      assert document = Registry.get("app.bsky.authFullApp")
      include = include("app.bsky.authFullApp", @appview)
      [rpc, repo] = PermissionSets.expand(include, document)

      assert %Permission{resource: :rpc, lxm: lxms} = rpc
      assert rpc.aud == @appview
      assert length(lxms) >= 100
      assert "app.bsky.actor.getPreferences" in lxms
      assert "app.bsky.feed.getFeedSkeleton" in lxms

      assert %Permission{
               resource: :repo,
               action: [:create, :update, :delete],
               collection: collections
             } =
               repo

      assert length(collections) == 17
      assert "app.bsky.feed.post" in collections
    end

    test "the vendored userinput set expands to its five collections" do
      # A set this server does not fetch from anyone: it is vendored beside the
      # Bluesky ones so a client that asks for it by include: resolves without
      # an aggregator configured.
      assert document = Registry.get("app.userinput.authBasic")
      include = include("app.userinput.authBasic", nil)
      [repo] = PermissionSets.expand(include, document)

      assert %Permission{
               resource: :repo,
               action: nil,
               collection: collections
             } = repo

      assert collections == [
               "app.userinput.discussion",
               "app.userinput.reply",
               "app.userinput.upvote",
               "app.userinput.downvote",
               "app.userinput.edit"
             ]
    end

    test "the chat set expands inside its own namespace" do
      assert document = Registry.get("chat.bsky.authFullChatClient")
      include = include("chat.bsky.authFullChatClient", "did:web:chat.example.com#svc")
      [rpc, repo] = PermissionSets.expand(include, document)

      assert %Permission{resource: :rpc, aud: "did:web:chat.example.com#svc", lxm: lxms} = rpc
      assert "chat.bsky.convo.getConvo" in lxms

      assert %Permission{resource: :repo, collection: ["chat.bsky.actor.declaration"]} = repo
    end

    test "a member outside the set's namespace is dropped, with a warning" do
      set = "app.example.feed.authonly"

      document =
        set_document(set, [
          repo_member(["app.example.feed.post"]),
          repo_member(["app.example.actor.profile"]),
          %{
            "type" => "permission",
            "resource" => "rpc",
            "inheritAud" => true,
            "lxm" => ["app.example.actor.getProfile"]
          }
        ])

      include = include(set, "did:web:api.example.com#svc")

      log =
        capture_log(fn ->
          assert [only] = PermissionSets.expand(include, document)
          assert only.collection == ["app.example.feed.post"]
        end)

      assert log =~ "outside the set's namespace"
    end

    test "an inheritAud member with no audience on the include is ignored" do
      set = "app.example.noaud"

      document =
        set_document(set, [
          repo_member(["app.example.post"]),
          %{
            "type" => "permission",
            "resource" => "rpc",
            "inheritAud" => true,
            "lxm" => ["app.example.feed.getFeed"]
          }
        ])

      assert [%Permission{resource: :repo}] = PermissionSets.expand(include(set, nil), document)
    end

    test "a member that names every service itself keeps its wildcard audience" do
      set = "app.example.selfaud"

      document =
        set_document(set, [
          %{
            "type" => "permission",
            "resource" => "rpc",
            "aud" => "*",
            "lxm" => ["app.example.feed.moderate"]
          }
        ])

      assert [%Permission{resource: :rpc, aud: "*", lxm: ["app.example.feed.moderate"]}] =
               PermissionSets.expand(include(set, "did:web:api.example.com#svc"), document)
    end

    test "every member the grammar cannot take is skipped" do
      set = "app.example.allskip"
      valid = repo_member(["app.example.post"])

      document =
        set_document(set, [
          valid,
          %{"type" => "record", "resource" => "repo", "collection" => ["app.example.post"]},
          %{"type" => "permission", "resource" => "storage", "size" => 1},
          %{"type" => "permission", "resource" => "blob", "accept" => ["*/*"]},
          %{"type" => "permission", "resource" => "account", "attr" => "email"},
          %{"type" => "permission", "resource" => "identity", "attr" => "handle"},
          %{"type" => "permission", "resource" => "include", "nsid" => "app.example.other"},
          %{"type" => "permission", "resource" => "repo", "collection" => ["*"]},
          %{"type" => "permission", "resource" => "rpc", "lxm" => ["*"], "aud" => "*"},
          %{
            "type" => "permission",
            "resource" => "rpc",
            "lxm" => ["app.example.get"],
            "aud" => "did:web:x.example#svc"
          },
          %{
            "type" => "permission",
            "resource" => "rpc",
            "lxm" => ["app.example.get"],
            "aud" => "*",
            "inheritAud" => true
          },
          %{
            "type" => "permission",
            "resource" => "repo",
            "collection" => ["app.example.post"],
            "extra" => true
          },
          %{"type" => "permission", "resource" => "rpc", "lxm" => ["app.example.get"]},
          %{"type" => "permission", "resource" => "repo", "collection" => "app.example.post"},
          %{"type" => "permission", "resource" => "repo", "collection" => []},
          %{
            "type" => "permission",
            "resource" => "repo",
            "collection" => ["app.example.post"],
            "action" => ["own"]
          },
          %{
            "type" => "permission",
            "resource" => "repo",
            "collection" => ["app.example.post"],
            "action" => ["create", "create"]
          },
          %{
            "type" => "permission",
            "resource" => "rpc",
            "lxm" => ["not-an-nsid"],
            "aud" => "*"
          }
        ])

      assert [%Permission{resource: :repo, collection: ["app.example.post"]}] =
               PermissionSets.expand(include(set, @appview), document)
    end

    test "a document that is not a permission-set expands to nothing" do
      document = %{
        "lexicon" => 1,
        "id" => "app.example.odd",
        "defs" => %{"main" => %{"type" => "lexicon", "record" => %{}}}
      }

      assert [] = PermissionSets.expand(include("app.example.odd", @appview), document)
    end
  end

  describe "namespace_allows?" do
    test "the set's namespace, less its own last segment, bounds every reference" do
      assert PermissionSets.namespace_allows?(
               "app.example.feed.authOnlyPost",
               "app.example.feed.post"
             )

      refute PermissionSets.namespace_allows?(
               "app.example.feed.authOnlyPost",
               "app.example.actor.profile"
             )

      assert PermissionSets.namespace_allows?("app.example.authFull", "app.example.feed.post")
      assert PermissionSets.namespace_allows?("app.example.authFull", "app.example.post")
      refute PermissionSets.namespace_allows?("app.example.authFull", "chat.example.post")

      # A whole segment or nothing: a longer name that merely shares a prefix
      # is a different namespace.
      refute PermissionSets.namespace_allows?("app.example.authFull", "app.examplefeed.post")
    end
  end

  describe "set_display" do
    @display_doc %{
      "lexicon" => 1,
      "id" => "app.example.localized",
      "defs" => %{
        "main" => %{
          "type" => "permission-set",
          "title" => "Base title",
          "detail" => "Base detail",
          "title:lang" => %{"fr" => "Titre"},
          "detail:lang" => %{"en" => "English detail", "en-GB" => "British detail"}
        }
      }
    }

    test "the base fields answer when no language is asked" do
      assert %{title: "Base title", detail: "Base detail"} =
               PermissionSets.set_display(@display_doc, nil)
    end

    test "an exact language tag wins, field by field" do
      assert %{title: "Base title", detail: "English detail"} =
               PermissionSets.set_display(@display_doc, "en")

      assert %{title: "Base title", detail: "British detail"} =
               PermissionSets.set_display(@display_doc, "en-GB")

      assert %{title: "Titre", detail: "Base detail"} =
               PermissionSets.set_display(@display_doc, "fr")
    end

    test "a language the document does not name falls back to the base fields" do
      assert %{title: "Base title", detail: "Base detail"} =
               PermissionSets.set_display(@display_doc, "de")
    end

    test "a document with no display fields at all shows empty strings" do
      document = %{
        "lexicon" => 1,
        "id" => "app.example.bare",
        "defs" => %{"main" => %{"type" => "permission-set", "permissions" => []}}
      }

      assert %{title: "", detail: ""} = PermissionSets.set_display(document, "en")
    end
  end

  describe "resolve" do
    test "the local registry wins over whatever the cache holds, and is never cached" do
      Cache.put("app.bsky.authFullApp", %{"poisoned" => true}, now_ms())

      assert {:ok, document} = PermissionSets.resolve("app.bsky.authFullApp")
      assert document["id"] == "app.bsky.authFullApp"

      assert {%{"poisoned" => true}, _at} = Cache.get("app.bsky.authFullApp")
    end

    test "a fresh cache row answers without asking the aggregator" do
      nsid = unique("fresh")
      document = set_document(nsid, [])
      Cache.put(nsid, document, now_ms())

      assert {:ok, ^document} = PermissionSets.resolve(nsid)
      assert called_times(nsid) == 0
    end

    test "a miss goes to the aggregator, whose answer is cached" do
      nsid = unique("miss")
      document = set_document(nsid, [])
      answer(nsid, {:ok, document})

      assert {:ok, ^document} = PermissionSets.resolve(nsid)
      assert called_times(nsid) == 1
      assert {^document, _at} = Cache.get(nsid)
    end

    test "a stale row is refreshed, and the stale answer stands when the fetch fails" do
      stale_nsid = unique("stale")
      document = set_document(stale_nsid, [])
      Cache.put(stale_nsid, document, now_ms() - 25 * 60 * 60 * 1000)

      fresh = set_document(stale_nsid, [repo_member(["app.example.post"])])
      answer(stale_nsid, {:ok, fresh})

      assert {:ok, ^fresh} = PermissionSets.resolve(stale_nsid)
      assert {^fresh, _at} = Cache.get(stale_nsid)

      failed_nsid = unique("stale-failed")
      old = set_document(failed_nsid, [])
      Cache.put(failed_nsid, old, now_ms() - 25 * 60 * 60 * 1000)
      answer(failed_nsid, {:error, :aggregator_down})

      assert {:ok, ^old} = PermissionSets.resolve(failed_nsid)
      assert {^old, _at} = Cache.get(failed_nsid)
    end

    test "a row past the expiration is refetched, and served to a refresh when the fetch fails" do
      expired_nsid = unique("expired")
      old = set_document(expired_nsid, [])
      Cache.put(expired_nsid, old, now_ms() - (Cache.expiration_ms() + 1))

      fresh = set_document(expired_nsid, [repo_member(["app.example.post"])])
      answer(expired_nsid, {:ok, fresh})

      assert {:ok, ^fresh} = PermissionSets.resolve(expired_nsid)

      failed_nsid = unique("expired-failed")
      old = set_document(failed_nsid, [])
      Cache.put(failed_nsid, old, now_ms() - (Cache.expiration_ms() + 1))
      answer(failed_nsid, {:error, :aggregator_down})

      assert {:ok, ^old} = PermissionSets.resolve(failed_nsid, allow_expired: true)

      assert {:error, {:unresolved_permission_set, ^failed_nsid}} =
               PermissionSets.resolve(failed_nsid)
    end

    test "a set that is nowhere and cannot be fetched is unresolved, with its nsid named" do
      nsid = unique("nowhere")

      assert {:error, {:unresolved_permission_set, ^nsid}} = PermissionSets.resolve(nsid)
    end
  end

  describe "the cache sweep" do
    test "rows past the expiration are reclaimed and current ones are kept" do
      old_nsid = unique("swept")
      live_nsid = unique("kept")

      Cache.put(old_nsid, %{}, now_ms() - (Cache.expiration_ms() + 1))
      Cache.put(live_nsid, %{"set" => true}, now_ms())

      Cache.handle_info(:sweep, nil)

      assert Cache.get(old_nsid) == nil
      assert {%{"set" => true}, _at} = Cache.get(live_nsid)
    end
  end

  describe "resolve_and_expand" do
    test "the include is replaced by its expansion where it sat; the rest passes through" do
      set = unique("inline")
      document = set_document(set, [repo_member(["app.example.post"], ["create", "delete"])])
      answer(set, {:ok, document})

      {:ok, grants} =
        PermissionSets.resolve_and_expand(
          Grants.parse(
            "atproto repo:app.bsky.feed.post?action=create " <>
              "include:#{set}?aud=did:web:api.example.com%23svc blob:image/*"
          )
        )

      assert [
               %Permission{resource: :repo, collection: ["app.bsky.feed.post"]},
               %Permission{
                 resource: :repo,
                 collection: ["app.example.post"],
                 action: [:create, :delete]
               },
               %Permission{resource: :blob, accept: ["image/*"]}
             ] = grants
    end

    test "one unresolvable set fails the whole answer" do
      nsid = unique("unresolved")

      assert {:error, {:unresolved_permission_set, ^nsid}} =
               PermissionSets.resolve_and_expand(
                 Grants.parse("atproto repo:app.bsky.feed.post include:#{nsid}")
               )
    end

    test "the stored grants form round-trips every resource a granular token holds" do
      {:ok, grants} =
        PermissionSets.resolve_and_expand(
          Grants.parse(
            "atproto repo:app.bsky.feed.post?action=create&action=update " <>
              "repo?collection=app.bsky.feed.like&collection=app.bsky.graph.follow&action=create " <>
              "blob:image/* blob?accept=video/*&accept=text/html " <>
              "account:email account:repo?action=manage " <>
              "identity:handle identity:* " <>
              "rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23appview"
          )
        )

      # What issue/5 stores: the canonical scope strings, space joined. What
      # verify_access_token and the plug read back: Grants.parse of it. The
      # two ends must meet, or a stored grant narrows to nothing.
      stored = Enum.map_join(grants, " ", &Permission.serialize/1)

      assert Grants.parse(stored) == grants
    end
  end

  # The helpers.

  defp include(nsid, aud), do: %Permission{resource: :include, nsid: nsid, aud: aud}

  defp set_document(id, permissions) do
    %{
      "lexicon" => 1,
      "id" => id,
      "defs" => %{
        "main" => %{
          "type" => "permission-set",
          "title" => "Synthetic set",
          "detail" => "Written by the test, for the test",
          "permissions" => permissions
        }
      }
    }
  end

  defp repo_member(collections, actions \\ nil) do
    member = %{"type" => "permission", "resource" => "repo", "collection" => collections}

    if actions, do: Map.put(member, "action", actions), else: member
  end

  defp answer(nsid, result),
    do: :persistent_term.put(:permission_sets_fake_answers, Map.put(fake_answers(), nsid, result))

  defp fake_answers, do: :persistent_term.get(:permission_sets_fake_answers, %{})

  defp called_times(nsid),
    do: :persistent_term.get(:permission_sets_fake_calls, %{}) |> Map.get(nsid, 0)

  defp now_ms, do: System.system_time(:millisecond)

  defp unique(prefix),
    do: "app.example." <> prefix <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
end
