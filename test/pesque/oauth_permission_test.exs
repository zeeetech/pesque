defmodule Pesque.OAuth.PermissionTest do
  @moduledoc """
  The permission grammar and the coverage question, driven directly.

  The valid strings are the specification's own examples plus the local ones;
  the invalid ones are its syntax and semantics tables. Every coverage rule
  the plug relies on is asserted here, because the plug cannot tell a
  matching failure from a grammar bug.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Permission

  # The parsed form of a scope string a test needs on the granted side.
  defp scope(string) do
    {:ok, permission} = Permission.parse_scope(string)
    permission
  end

  @valid [
    "atproto",
    "transition:generic",
    "transition:chat.bsky",
    "transition:email",
    "identity:*",
    "identity:*?",
    "identity:handle",
    "rpc?lxm=*&aud=did:web:api.example.com%23svc_appview",
    "blob?accept=video/*&accept=text/html",
    "repo:app.example.profile?action=create&action=update&action=delete",
    "include:app.example.authFull?aud=did:web:api.example.com%23svc_chat",
    "include:app.example.authFull",
    "account:repo?action=manage",
    "account:email",
    "account:email?action=read",
    "repo?collection=app.example.profile&collection=app.example.post",
    "blob:*/*",
    "blob:image/*",
    "rpc:app.example.moderation.createReport?aud=*",
    "repo:*",
    "repo:*?action=delete",
    "repo:app.bsky.feed.post",
    "rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23appview",
    "rpc:app.example.get?aud=did:web:api.example.com:8443%23svc"
  ]

  test "every valid scope string parses into the permission it names" do
    assert {:ok, %Permission{resource: :atproto}} = Permission.parse_scope("atproto")

    assert {:ok, %Permission{resource: :transition_generic}} =
             Permission.parse_scope("transition:generic")

    assert {:ok, %Permission{resource: :transition_chat}} =
             Permission.parse_scope("transition:chat.bsky")

    assert {:ok, %Permission{resource: :transition_email}} =
             Permission.parse_scope("transition:email")

    assert {:ok, %Permission{resource: :identity, attr: :*}} =
             Permission.parse_scope("identity:*")

    assert {:ok, %Permission{resource: :identity, attr: :handle}} =
             Permission.parse_scope("identity:handle")

    assert {:ok, %Permission{lxm: ["*"], aud: "did:web:api.example.com#svc_appview"}} =
             Permission.parse_scope("rpc?lxm=*&aud=did:web:api.example.com%23svc_appview")

    assert {:ok, %Permission{accept: ["video/*", "text/html"]}} =
             Permission.parse_scope("blob?accept=video/*&accept=text/html")

    assert {:ok,
            %Permission{
              collection: ["app.example.profile"],
              action: [:create, :update, :delete]
            }} =
             Permission.parse_scope(
               "repo:app.example.profile?action=create&action=update&action=delete"
             )

    assert {:ok, %Permission{resource: :include, nsid: "app.example.authFull"}} =
             Permission.parse_scope("include:app.example.authFull")

    assert {:ok, %Permission{resource: :account, attr: :repo, action: :manage}} =
             Permission.parse_scope("account:repo?action=manage")

    assert {:ok, %Permission{resource: :account, attr: :email, action: :read}} =
             Permission.parse_scope("account:email")

    assert {:ok,
            %Permission{collection: ["app.example.profile", "app.example.post"], action: nil}} =
             Permission.parse_scope(
               "repo?collection=app.example.profile&collection=app.example.post"
             )

    assert {:ok, %Permission{accept: ["*/*"]}} = Permission.parse_scope("blob:*/*")

    assert {:ok,
            %Permission{resource: :rpc, lxm: ["app.example.moderation.createReport"], aud: "*"}} =
             Permission.parse_scope("rpc:app.example.moderation.createReport?aud=*")

    assert {:ok, %Permission{collection: ["*"], action: nil}} = Permission.parse_scope("repo:*")

    assert {:ok, %Permission{collection: ["*"], action: [:delete]}} =
             Permission.parse_scope("repo:*?action=delete")

    # The audience decodes back into the DID reference it names, percent or not.
    assert {:ok, %Permission{aud: "did:web:api.bsky.app#appview"}} =
             Permission.parse_scope(
               "rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23appview"
             )
  end

  test "the specification's invalid-semantics strings are refused, each for a named reason" do
    assert {:error, {:unknown_resource, "resource"}} = Permission.parse_scope("resource")

    assert {:error, {:unknown_resource, "resource"}} =
             Permission.parse_scope("resource:positional?key=val")

    assert {:error, {:unknown_resource, "resource"}} =
             Permission.parse_scope("resource:positional&thing?key=val")

    assert {:error, {:unknown_resource, "service"}} =
             Permission.parse_scope("service:did:web:com.example#type?key=val")

    # The resource is known, the positional is not.
    assert {:error, {:bad_positional, :repo}} = Permission.parse_scope("repo:")

    # An empty positional is a missing one, so a bare word tolerates the
    # trailing colon; a resource that requires its positional does not.
    assert {:ok, %Permission{resource: :atproto}} = Permission.parse_scope("atproto:")
    assert {:error, {:bad_positional, :transition}} = Permission.parse_scope("transition:")

    assert {:error, {:unknown_scope, "transition:something-else"}} =
             Permission.parse_scope("transition:something-else")

    assert {:error, {:bad_positional, :atproto}} = Permission.parse_scope("atproto:write")
  end

  test "the specification's invalid-syntax strings are refused" do
    assert {:error, :invalid_characters} =
             Permission.parse_scope("resource:positional?key=québec")

    assert {:error, :invalid_characters} = Permission.parse_scope("emoji:☺️")
  end

  test "a parameter may not ride both positionally and by name" do
    assert {:error, {:bad_positional, :repo}} =
             Permission.parse_scope("repo:com.example.record?collection=com.example.other")

    assert {:error, {:bad_positional, :rpc}} =
             Permission.parse_scope("rpc:com.example.report?lxm=com.example.other")
  end

  test "a partial wildcard is refused wherever one rides" do
    assert {:error, :wildcard_not_allowed} = Permission.parse_scope("repo:com.example.*")
    assert {:error, :wildcard_not_allowed} = Permission.parse_scope("rpc:com.example.*")

    assert {:error, :wildcard_not_allowed} =
             Permission.parse_scope("repo?collection=app.example.*&collection=app.example.post")

    assert {:error, :wildcard_not_allowed} = Permission.parse_scope("account:*")
  end

  test "rpc without an audience, and with both wildcards, is refused" do
    assert {:error, :missing_aud} =
             Permission.parse_scope("rpc:app.example.moderation.createReport")

    assert {:error, :missing_aud} = Permission.parse_scope("rpc?lxm=app.example.get")
    assert {:error, :both_rpc_wildcards} = Permission.parse_scope("rpc?lxm=*&aud=*")
  end

  test "an audience that is not a DID service reference is refused" do
    for aud <- ["did:web:api.example.com", "relay.example.com#svc", "did:ethr:x#y", "http://x#y"] do
      assert {:error, {:bad_parameter, "aud"}} =
               Permission.parse_scope("rpc:app.example.get?aud=" <> aud),
             aud
    end
  end

  test "parameters the resource does not know are refused by name" do
    assert {:error, {:bad_parameter, "foo"}} =
             Permission.parse_scope("repo:com.example.x?foo=bar")

    assert {:error, {:bad_parameter, "collection"}} =
             Permission.parse_scope("rpc?collection=a&aud=*")

    assert {:error, {:bad_parameter, "action"}} =
             Permission.parse_scope("identity:handle?action=manage")
  end

  test "bad values are refused by the parameter that carries them" do
    assert {:error, {:bad_parameter, "action"}} =
             Permission.parse_scope("account:email?action=delete")

    assert {:error, {:bad_parameter, "action"}} =
             Permission.parse_scope("account:email?action=read&action=manage")

    assert {:error, {:bad_parameter, "action"}} =
             Permission.parse_scope("repo:app.example.x?action=create&action=create")

    assert {:error, {:bad_parameter, "action"}} =
             Permission.parse_scope("repo:app.example.x?action=create&action=nope")

    assert {:error, {:bad_parameter, "collection"}} =
             Permission.parse_scope("repo:app.example.x/x")

    assert {:error, {:bad_parameter, "accept"}} = Permission.parse_scope("blob:noslash")
    assert {:error, {:bad_parameter, "accept"}} = Permission.parse_scope("blob:image//")
    assert {:error, {:bad_parameter, "attr"}} = Permission.parse_scope("account:handle")
  end

  test "percent escapes decode and malformed ones are refused" do
    assert {:error, :invalid_syntax} = Permission.parse_scope("repo:app.example.x%zz")
    assert {:error, :invalid_syntax} = Permission.parse_scope("repo:app.example.x%2")
    assert {:error, :invalid_syntax} = Permission.parse_scope("repo:app.example.x%")
    assert {:error, :invalid_syntax} = Permission.parse_scope("repo:app.example.x?action=%zz")

    # A decoded "/" is a byte in the value, not a collection separator.
    assert {:ok, %Permission{accept: ["image/jpeg"]}} =
             Permission.parse_scope("blob:image%2Fjpeg")

    assert {:ok, %Permission{aud: "did:web:x.example#svc", accept: []}} =
             Permission.parse_scope("rpc:app.example.get?aud=did:web:x.example%23svc")
  end

  test "a required positional cannot be replaced by parameters that are not its own" do
    assert {:error, {:bad_positional, :include}} =
             Permission.parse_scope("include?aud=did:web:x.example%23s")

    assert {:error, {:bad_parameter, "attr"}} =
             Permission.parse_scope("account?attr=email&attr=email")
  end

  test "canonical strings serialize back onto themselves" do
    for scope <- @valid do
      assert {:ok, permission} = Permission.parse_scope(scope)
      canonical = Permission.serialize(permission)
      assert {:ok, round_tripped} = Permission.parse_scope(canonical)
      assert round_tripped == permission, "#{scope} -> #{canonical}"
    end
  end

  test "several values serialize as parameters, one as the positional" do
    {:ok, multi} = Permission.parse_scope("blob?accept=video/*&accept=text/html")
    assert Permission.serialize(multi) == "blob?accept=video/*&accept=text/html"

    {:ok, one} = Permission.parse_scope("blob:image/*")
    assert Permission.serialize(one) == "blob:image/*"

    {:ok, set} =
      Permission.parse_scope("repo?collection=app.example.profile&collection=app.example.post")

    assert Permission.serialize(set) ==
             "repo?collection=app.example.profile&collection=app.example.post"

    {:ok, with_aud} =
      Permission.parse_scope(
        "include:app.example.authFull?aud=did:web:api.example.com%23svc_chat"
      )

    assert Permission.serialize(with_aud) ==
             "include:app.example.authFull?aud=did:web:api.example.com%23svc_chat"

    # A "#" in a parameter value is emitted encoded; the positional never
    # needs an escape.
    {:ok, account} = Permission.parse_scope("account:repo?action=manage")
    assert Permission.serialize(account) == "account:repo?action=manage"
  end

  describe "covers?" do
    test "atproto covers everything, as the compatibility grant" do
      for required <- [
            Permission.repo_required("app.example.post", [:delete]),
            Permission.rpc_required(:any, "did:web:relay.example.com"),
            Permission.blob_required("video/mp4"),
            Permission.account_required(:repo, :manage),
            Permission.identity_required(:*)
          ] do
        assert Permission.covers?(%Permission{resource: :atproto}, required)
      end
    end

    test "transition:generic reaches records, blobs and non-chat rpc, and nothing above them" do
      generic = %Permission{resource: :transition_generic}

      assert Permission.covers?(generic, Permission.repo_required("app.example.post", [:create]))
      assert Permission.covers?(generic, Permission.repo_required("*", [:delete]))
      assert Permission.covers?(generic, Permission.blob_required("video/mp4"))

      assert Permission.covers?(
               generic,
               Permission.rpc_required("app.example.get", "did:web:x.example#a")
             )

      refute Permission.covers?(
               generic,
               Permission.rpc_required("chat.bsky.convos.getMessages", "did:web:x#a")
             )

      refute Permission.covers?(generic, Permission.rpc_required(:any, "did:web:x.example#a"))
      refute Permission.covers?(generic, Permission.account_required(:email, :read))
      refute Permission.covers?(generic, Permission.account_required(:repo, :manage))
      refute Permission.covers?(generic, Permission.identity_required(:handle))
    end

    test "transition:chat.bsky reaches only chat methods, by name" do
      chat = %Permission{resource: :transition_chat}

      assert Permission.covers?(
               chat,
               Permission.rpc_required("chat.bsky.convos.getMessages", "did:web:x#a")
             )

      refute Permission.covers?(
               chat,
               Permission.rpc_required("app.example.get", "did:web:x.example#a")
             )

      refute Permission.covers?(chat, Permission.rpc_required(:any, "did:web:x.example#a"))
      refute Permission.covers?(chat, Permission.repo_required("app.example.post", [:create]))
    end

    test "transition:email covers no permission, only the email question" do
      email = %Permission{resource: :transition_email}

      refute Permission.covers?(email, Permission.account_required(:email, :read))
      refute Permission.covers?(email, Permission.repo_required("*", [:create]))
    end

    test "repo grants cover the collections and actions they name" do
      post = Permission.repo_required("app.bsky.feed.post", [:create])

      assert Permission.covers?(
               scope("repo:app.bsky.feed.post"),
               post
             )

      assert Permission.covers?(
               scope("repo:app.bsky.feed.post?action=create"),
               post
             )

      assert Permission.covers?(scope("repo:*"), post)
      refute Permission.covers?(scope("repo:app.bsky.feed.like"), post)
      refute Permission.covers?(scope("repo:app.bsky.feed.post?action=update"), post)
      refute Permission.covers?(scope("repo:app.bsky.feed.post?action=delete"), post)

      # putRecord is an upsert: it needs both actions of the same collection.
      upsert = Permission.repo_required("app.bsky.feed.post", [:create, :update])
      assert Permission.covers?(scope("repo:app.bsky.feed.post"), upsert)
      refute Permission.covers?(scope("repo:app.bsky.feed.post?action=create"), upsert)
    end

    test "rpc grants cover the methods and the one service they name" do
      required = Permission.rpc_required("app.example.get", "did:web:api.example.com#svc")

      assert Permission.covers?(
               scope("rpc:app.example.get?aud=did:web:api.example.com%23svc"),
               required
             )

      assert Permission.covers?(
               scope("rpc?lxm=*&aud=did:web:api.example.com%23svc"),
               required
             )

      assert Permission.covers?(
               scope("rpc:app.example.get?aud=*"),
               required
             )

      refute Permission.covers?(
               scope("rpc:app.example.get?aud=did:web:other.example%23svc"),
               required
             )

      refute Permission.covers?(
               scope("rpc:app.example.other?aud=did:web:api.example.com%23svc"),
               required
             )

      # The method-unscoped form needs the literal wildcard.
      unscoped = Permission.rpc_required(:any, "did:web:relay.example.com#svc")

      assert Permission.covers?(
               scope("rpc?lxm=*&aud=did:web:relay.example.com%23svc"),
               unscoped
             )

      refute Permission.covers?(
               scope("rpc:app.example.get?aud=did:web:relay.example.com%23svc"),
               unscoped
             )
    end

    test "blob grants cover by glob tier" do
      image = Permission.blob_required("image/jpeg")

      assert Permission.covers?(scope("blob:*/*"), image)
      assert Permission.covers?(scope("blob:image/*"), image)
      assert Permission.covers?(scope("blob:image/jpeg"), image)
      refute Permission.covers?(scope("blob:video/*"), image)
      refute Permission.covers?(scope("blob:image/png"), image)
    end

    test "account manage covers read, and nothing crosses attributes" do
      assert Permission.covers?(
               scope("account:repo?action=manage"),
               Permission.account_required(:repo, :manage)
             )

      assert Permission.covers?(
               scope("account:repo?action=manage"),
               Permission.account_required(:repo, :read)
             )

      refute Permission.covers?(
               scope("account:repo"),
               Permission.account_required(:repo, :manage)
             )

      refute Permission.covers?(
               scope("account:email"),
               Permission.account_required(:repo, :read)
             )
    end

    test "identity:* covers the handle, and the handle does not cover everything" do
      assert Permission.covers?(
               scope("identity:*"),
               Permission.identity_required(:handle)
             )

      assert Permission.covers?(
               scope("identity:*"),
               Permission.identity_required(:*)
             )

      assert Permission.covers?(
               scope("identity:handle"),
               Permission.identity_required(:handle)
             )

      refute Permission.covers?(
               scope("identity:handle"),
               Permission.identity_required(:*)
             )
    end

    test "include covers nothing on its own" do
      {:ok, include} = Permission.parse_scope("include:app.example.authFull")

      refute Permission.covers?(include, Permission.repo_required("*", [:create]))
    end
  end

  describe "from_set_member" do
    test "a repo member parses with its actions" do
      assert {:ok, %Permission{resource: :repo, collection: ["app.example.post"], action: nil}} =
               Permission.from_set_member(%{
                 "type" => "permission",
                 "resource" => "repo",
                 "collection" => ["app.example.post"]
               })

      assert {:ok, %Permission{action: [:delete]}} =
               Permission.from_set_member(%{
                 "type" => "permission",
                 "resource" => "repo",
                 "collection" => ["app.example.like"],
                 "action" => ["delete"]
               })
    end

    test "an rpc member parses with a wildcard audience or an inherited one" do
      assert {:ok, %Permission{resource: :rpc, lxm: ["app.example.get"], aud: "*"}} =
               Permission.from_set_member(%{
                 "type" => "permission",
                 "resource" => "rpc",
                 "lxm" => ["app.example.get"],
                 "aud" => "*"
               })

      assert {:ok, %Permission{resource: :rpc, lxm: ["app.example.get"], aud: nil}} =
               Permission.from_set_member(%{
                 "type" => "permission",
                 "resource" => "rpc",
                 "lxm" => ["app.example.get"],
                 "inheritAud" => true
               })
    end

    test "every ignore rule answers :skip" do
      skipped = [
        {"not a permission type",
         %{"type" => "record", "resource" => "repo", "collection" => ["app.x.post"]}},
        {"unknown resource", %{"type" => "permission", "resource" => "storage", "size" => 1}},
        {"blob in a set", %{"type" => "permission", "resource" => "blob", "accept" => ["*/*"]}},
        {"account in a set",
         %{"type" => "permission", "resource" => "account", "attr" => "email"}},
        {"identity in a set",
         %{"type" => "permission", "resource" => "identity", "attr" => "handle"}},
        {"include in a set",
         %{"type" => "permission", "resource" => "include", "nsid" => "app.x.set"}},
        {"wildcard collection",
         %{"type" => "permission", "resource" => "repo", "collection" => ["*"]}},
        {"wildcard lxm",
         %{"type" => "permission", "resource" => "rpc", "lxm" => ["*"], "aud" => "*"}},
        {"aud is a DID reference",
         %{
           "type" => "permission",
           "resource" => "rpc",
           "lxm" => ["app.x.get"],
           "aud" => "did:web:x.example#svc"
         }},
        {"inheritAud and aud together",
         %{
           "type" => "permission",
           "resource" => "rpc",
           "lxm" => ["app.x.get"],
           "aud" => "*",
           "inheritAud" => true
         }},
        {"unknown key",
         %{
           "type" => "permission",
           "resource" => "repo",
           "collection" => ["app.x.post"],
           "extra" => true
         }},
        {"aud missing without inheritAud",
         %{"type" => "permission", "resource" => "rpc", "lxm" => ["app.x.get"]}},
        {"collection not a list",
         %{"type" => "permission", "resource" => "repo", "collection" => "app.x.post"}},
        {"collection empty", %{"type" => "permission", "resource" => "repo", "collection" => []}},
        {"bad action value",
         %{
           "type" => "permission",
           "resource" => "repo",
           "collection" => ["app.x.post"],
           "action" => ["own"]
         }},
        {"duplicate actions",
         %{
           "type" => "permission",
           "resource" => "repo",
           "collection" => ["app.x.post"],
           "action" => ["create", "create"]
         }}
      ]

      for {why, member} <- skipped do
        assert Permission.from_set_member(member) == :skip, why
      end
    end

    test "to_set_member is the inverse for the shapes a set may hold" do
      {:ok, repo} =
        Permission.from_set_member(%{
          "type" => "permission",
          "resource" => "repo",
          "collection" => ["app.example.post"],
          "action" => ["create", "delete"]
        })

      assert Permission.to_set_member(repo) == %{
               "type" => "permission",
               "resource" => "repo",
               "collection" => ["app.example.post"],
               "action" => ["create", "delete"]
             }

      {:ok, rpc} =
        Permission.from_set_member(%{
          "type" => "permission",
          "resource" => "rpc",
          "lxm" => ["app.example.get"],
          "aud" => "*"
        })

      assert Permission.to_set_member(rpc) == %{
               "type" => "permission",
               "resource" => "rpc",
               "lxm" => ["app.example.get"],
               "aud" => "*"
             }
    end
  end

  describe "describe" do
    test "every resource has a sentence" do
      for scope <- @valid do
        {:ok, permission} = Permission.parse_scope(scope)
        assert is_binary(Permission.describe(permission))
        assert Permission.describe(permission) != ""
      end
    end

    test "the transitional grants say how broad they are" do
      {:ok, generic} = Permission.parse_scope("transition:generic")
      assert Permission.describe(generic) =~ "broad"
    end
  end

  describe "requirement builders" do
    test "the required side never carries a wildcard" do
      required = Permission.rpc_required("app.example.get", "did:web:x.example#svc")
      assert required.lxm == ["app.example.get"]

      unscoped = Permission.rpc_required(:any, "did:web:x.example#svc")
      assert unscoped.lxm == :any

      assert Permission.blob_required("Image/JPEG; charset=binary").accept == ["image/jpeg"]
      assert Permission.account_required(:repo, :manage).action == :manage
      assert Permission.identity_required(:*).attr == :*

      assert Permission.repo_required("app.example.post", [:create, :update]).action == [
               :create,
               :update
             ]
    end
  end
end
