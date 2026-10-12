defmodule PesqueWeb.PermissionEnforcementTest do
  @moduledoc """
  The route-to-requirement matrix over real requests: for each route, a token
  whose grants are exactly what the requirement asks for reaches the
  controller's own answer, a token without it gets 403 naming the serialized
  scope, and a request whose facts are malformed still gets the controller's
  400 or 415 rather than a 403 for something else.

  The fixture tokens are minted through the whole OAuth flow, so what is
  tested is the granted scope string, checkboxes and all.
  """

  use PesqueWeb.ConnCase, async: false

  alias PesqueWeb.OAuthCase, as: Client

  defmodule Directory do
    def resolve(did) do
      documents = :persistent_term.get(:permission_enforcement_documents, %{})
      Map.get(documents, did, {:error, :not_found})
    end
  end

  defmodule Fetch do
    def request(_uri, _method, _headers, _body, _opts) do
      {:ok, 200, [{"content-type", "application/json"}], ~s({"ok":true})}
    end
  end

  @appview "did:web:api.bsky.app%23appview"
  @target "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @request_id "0123456789abcdef0123456789abcdef"

  setup do
    user = create_account("alice")

    # The proxy needs a target that resolves and answers, so the resolver and
    # fetcher are injected the way the proxy suite does it.
    :persistent_term.put(:permission_enforcement_pid, self())
    :persistent_term.put(:permission_enforcement_documents, documents())
    Application.put_env(:pesque, :did_resolver_directory, Directory)
    Application.put_env(:pesque, :entryway_fetch, Fetch)

    on_exit(fn ->
      :persistent_term.erase(:permission_enforcement_pid)
      :persistent_term.erase(:permission_enforcement_documents)
      Application.delete_env(:pesque, :did_resolver_directory)
      Application.delete_env(:pesque, :entryway_fetch)
    end)

    tangled =
      "atproto " <>
        "repo:app.bsky.feed.post?action=create&action=update " <>
        "repo:app.bsky.feed.like?action=create " <>
        "repo:app.bsky.graph.follow?action=create " <>
        "blob:image/* " <>
        "rpc:app.bsky.feed.getFeedSkeleton?aud=#{@appview}"

    %{
      user: user,
      full: oauth_token(user, "atproto"),
      generic: oauth_token(user, "atproto transition:generic"),
      chat: oauth_token(user, "atproto transition:generic transition:chat.bsky"),
      email: oauth_token(user, "atproto transition:email"),
      tangled: oauth_token(user, tangled),
      proxy:
        oauth_token(
          user,
          "atproto rpc:app.bsky.feed.getFeedSkeleton?aud=#{@target}%23bsky_appview"
        ),
      identity: oauth_token(user, "atproto identity:handle"),
      importer: oauth_token(user, "atproto account:repo?action=manage"),
      rpc_prefs: oauth_token(user, "atproto rpc:app.bsky.actor.getPreferences?aud=#{@appview}"),
      session_token: token(user),
      app_token: app_password_session(user, false),
      app_privileged_token: app_password_session(user, true)
    }
  end

  # getSession: any valid token, with the email gated in the controller.

  test "getSession answers any valid token and gates the email on the grants", ctx do
    full = session_get(ctx.full)
    assert full.status == 200
    assert Client.json(full)["email"]

    assert Client.json(session_get(ctx.email))["email"]
    assert Client.json(session_get(ctx.session_token))["email"]

    # The generic transition is an app password, and an app password never
    # saw the email. The legacy session tier is the same shape: the
    # non-privileged app-password scope computes to transition:generic, so
    # its gate answers identically, and the privileged tier is the full
    # grant, as a password login is.
    generic = session_get(ctx.generic)
    assert generic.status == 200
    refute Map.has_key?(Client.json(generic), "email")

    app = session_get(ctx.app_token)
    assert app.status == 200
    refute Map.has_key?(Client.json(app), "email")

    assert Client.json(session_get(ctx.app_privileged_token))["email"]
  end

  test "getSession with no token is 401" do
    conn = xrpc_get("/xrpc/com.atproto.server.getSession")
    assert conn.status == 401
  end

  # getServiceAuth: an rpc permission naming the lxm and the audience.

  test "getServiceAuth with an lxm passes to a grant that names both", ctx do
    conn =
      service_auth(ctx.tangled, "did:web:api.bsky.app#appview", "app.bsky.feed.getFeedSkeleton")

    assert conn.status == 200
    assert Client.json(conn)["token"]
  end

  test "getServiceAuth with an lxm answers 403 naming the rpc permission", ctx do
    for {sess, aud, lxm, needed} <- [
          {ctx.tangled, "did:web:relay.example.com", "app.bsky.feed.getFeedSkeleton",
           "rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:relay.example.com"},
          {ctx.tangled, "did:web:api.bsky.app#appview", "app.bsky.actor.getProfile",
           "rpc:app.bsky.actor.getProfile?aud=did:web:api.bsky.app%23appview"}
        ] do
      conn = service_auth(sess, aud, lxm)

      assert conn.status == 403
      assert Client.json(conn)["error"] == "InsufficientScope"
      assert Client.json(conn)["message"] == "this token does not grant #{needed}"

      assert challenge(conn) =~ ~s(error="insufficient_scope")
    end
  end

  test "getServiceAuth without an lxm needs the literal wildcard grant", ctx do
    for sess <- [ctx.tangled, ctx.generic, ctx.chat] do
      conn = service_auth(sess, "did:web:relay.example.com", nil)

      assert conn.status == 403, inspect(sess)

      assert Client.json(conn)["message"] ==
               "this token does not grant rpc?lxm=*&aud=did:web:relay.example.com"
    end

    assert service_auth(ctx.full, "did:web:relay.example.com", nil).status == 200
    assert service_auth(ctx.session_token, "did:web:relay.example.com", nil).status == 200
  end

  test "a missing audience is the controller's 400, not a 403", ctx do
    conn = authorized_get(ctx.generic, "/xrpc/com.atproto.server.getServiceAuth")

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  test "chat service auth passes to the chat transition and not to the generic one", ctx do
    aud = "did:web:chat.example.com#svc"

    assert service_auth(ctx.chat, aud, "chat.bsky.convo.getMessages").status == 200

    conn = service_auth(ctx.generic, aud, "chat.bsky.convo.getMessages")
    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant rpc:chat.bsky.convo.getMessages?aud=did:web:chat.example.com%23svc"
  end

  # getRecommendedDidCredentials: identity:handle.

  test "getRecommendedDidCredentials passes to identity:handle and to atproto", ctx do
    assert authorized_get(ctx.identity, "/xrpc/com.atproto.identity.getRecommendedDidCredentials").status ==
             200

    assert authorized_get(ctx.full, "/xrpc/com.atproto.identity.getRecommendedDidCredentials").status ==
             200
  end

  test "getRecommendedDidCredentials answers 403 to a token without an identity grant", ctx do
    conn = authorized_get(ctx.tangled, "/xrpc/com.atproto.identity.getRecommendedDidCredentials")

    assert conn.status == 403
    assert Client.json(conn)["message"] == "this token does not grant identity:handle"
  end

  # listMissingBlobs: any valid token on top of the read budget.

  test "listMissingBlobs answers any valid token", ctx do
    assert authorized_get(ctx.generic, "/xrpc/com.atproto.repo.listMissingBlobs").status == 200
  end

  # Account management: the atproto tier, and nothing else.

  test "requestAccountDelete passes to atproto and answers 403 to a narrower grant", ctx do
    assert authorized_post(ctx.full, "/xrpc/com.atproto.server.requestAccountDelete", %{}).status ==
             200

    conn =
      authorized_post(ctx.generic, "/xrpc/com.atproto.server.requestAccountDelete", %{})

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant account management (the atproto scope)"
  end

  test "deleteAccount with atproto reaches the controller's own validation", ctx do
    conn = authorized_post(ctx.full, "/xrpc/com.atproto.server.deleteAccount", %{})

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  test "deactivate and activate pass to atproto and 403 to the generic transition", ctx do
    user = create_account("deactivatable")
    sess = oauth_token(user, "atproto")

    assert authorized_post(sess, "/xrpc/com.atproto.server.deactivateAccount", %{}).status == 200
    assert authorized_post(sess, "/xrpc/com.atproto.server.activateAccount", %{}).status == 200

    conn = authorized_post(ctx.generic, "/xrpc/com.atproto.server.deactivateAccount", %{})
    assert conn.status == 403
  end

  test "createInviteCodes answers 403 to a grant that is not the atproto tier", ctx do
    conn = authorized_post(ctx.generic, "/xrpc/com.atproto.server.createInviteCodes", %{})

    assert conn.status == 403
    assert Client.json(conn)["error"] == "InsufficientScope"
  end

  # Repo writes: one requirement per action, named by collection.

  test "createRecord passes when the grant names the collection and the action", ctx do
    conn = create_record(ctx.tangled, ctx.user.did, "app.bsky.feed.post")

    assert conn.status == 200
    assert Client.json(conn)["uri"]
  end

  test "createRecord answers 403 naming the repo permission it is missing", ctx do
    for {sess, collection, message} <- [
          {ctx.tangled, "app.bsky.graph.block", "repo:app.bsky.graph.block?action=create"},
          {ctx.identity, "app.bsky.feed.post", "repo:app.bsky.feed.post?action=create"}
        ] do
      conn = create_record(sess, ctx.user.did, collection)

      assert conn.status == 403, collection
      assert Client.json(conn)["message"] == "this token does not grant #{message}"
    end
  end

  test "putRecord needs create and update on the same collection", ctx do
    assert put_record(ctx.tangled, ctx.user.did, "app.bsky.feed.post").status == 200

    conn = put_record(ctx.tangled, ctx.user.did, "app.bsky.feed.like")
    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant repo:app.bsky.feed.like?action=create&action=update"
  end

  test "deleteRecord needs the delete action, which the fixture does not carry", ctx do
    conn = delete_record(ctx.tangled, ctx.user.did)

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant repo:app.bsky.feed.post?action=delete"
  end

  test "a write without a collection is the controller's 400, not a 403", ctx do
    conn =
      authorized_post(ctx.tangled, "/xrpc/com.atproto.repo.createRecord", %{
        "repo" => ctx.user.did,
        "record" => post_record("no collection")
      })

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  test "a collection that is not an NSID is the controller's 400, not a 403", ctx do
    conn = create_record(ctx.tangled, ctx.user.did, "not an nsid")

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  # applyWrites: every write's permission, because the endpoint is atomic.

  test "applyWrites passes when every write is covered", ctx do
    conn =
      apply_writes(ctx.tangled, ctx.user.did, [
        %{
          "$type" => "com.atproto.repo.applyWrites#create",
          "collection" => "app.bsky.feed.post",
          "value" => post_record("one")
        },
        %{
          "$type" => "com.atproto.repo.applyWrites#create",
          "collection" => "app.bsky.feed.post",
          "value" => post_record("two")
        }
      ])

    assert conn.status == 200
    assert length(Client.json(conn)["results"]) == 2
  end

  test "applyWrites answers 403 naming the first write that is not covered", ctx do
    conn =
      apply_writes(ctx.tangled, ctx.user.did, [
        %{
          "$type" => "com.atproto.repo.applyWrites#create",
          "collection" => "app.bsky.feed.post",
          "value" => post_record("one")
        },
        %{"$type" => "com.atproto.repo.applyWrites#delete", "collection" => "app.bsky.feed.like"}
      ])

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant repo:app.bsky.feed.like?action=delete"
  end

  test "a writes value that is not a list of shaped writes is the controller's 400", ctx do
    conn =
      authorized_post(ctx.tangled, "/xrpc/com.atproto.repo.applyWrites", %{"writes" => "nope"})

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"

    conn =
      authorized_post(ctx.tangled, "/xrpc/com.atproto.repo.applyWrites", %{
        "writes" => [%{"action" => "create"}]
      })

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  # uploadBlob: a blob permission naming the content type.

  test "uploadBlob passes when the grant covers the content type", ctx do
    conn = upload_blob(ctx.tangled, "hello", "image/jpeg")
    assert conn.status == 200
    assert Client.json(conn)["blob"]["ref"]["$link"]

    assert upload_blob(ctx.generic, "hello", "video/mp4").status == 200
  end

  test "uploadBlob answers 403 naming the blob permission", ctx do
    conn = upload_blob(ctx.tangled, "hello", "video/mp4")

    assert conn.status == 403
    assert Client.json(conn)["message"] == "this token does not grant blob:video/mp4"
  end

  test "a json body to uploadBlob is the controller's 415, not a 403", ctx do
    conn = upload_blob(ctx.tangled, JSON.encode!(%{"hello" => "world"}), "application/json")

    assert conn.status == 415
    assert Client.json(conn)["error"] == "UnsupportedMediaType"
  end

  # importRepo: account:repo manage, which no transitional grant reaches.

  test "importRepo passes to account:repo manage and 403 to the generic transition", ctx do
    conn = authorized_post(ctx.importer, "/xrpc/com.atproto.repo.importRepo", %{})

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
    assert Client.json(conn)["message"] =~ "content-length"

    conn = authorized_post(ctx.generic, "/xrpc/com.atproto.repo.importRepo", %{})
    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant account:repo?action=manage"
  end

  # Preferences: the transitional grants, or an rpc naming the method.

  test "getPreferences passes to the generic transition and to a named rpc grant", ctx do
    assert authorized_get(ctx.generic, "/xrpc/app.bsky.actor.getPreferences").status == 200
    assert authorized_get(ctx.rpc_prefs, "/xrpc/app.bsky.actor.getPreferences").status == 200
  end

  test "getPreferences answers 403 naming the rpc permission it needs", ctx do
    conn = authorized_get(ctx.tangled, "/xrpc/app.bsky.actor.getPreferences")

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant rpc:app.bsky.actor.getPreferences"
  end

  test "putPreferences answers 403 to a grant that names only the read", ctx do
    conn =
      authorized_post(ctx.rpc_prefs, "/xrpc/app.bsky.actor.putPreferences", %{
        "preferences" => []
      })

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant rpc:app.bsky.actor.putPreferences"
  end

  # The proxy: an rpc permission naming the method and the did#serviceId.

  test "a proxied call passes to the grant that names its target", ctx do
    conn = proxy(ctx.proxy, "/xrpc/app.bsky.feed.getFeedSkeleton", appview_proxy())

    assert conn.status == 200
    assert conn.resp_body == ~s({"ok":true})
  end

  test "a proxied call answers 403 to a grant that names another target", ctx do
    conn = proxy(ctx.proxy, "/xrpc/app.bsky.feed.getTimeline", appview_proxy())

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant rpc:app.bsky.feed.getTimeline?aud=#{@target}%23bsky_appview"
  end

  test "chat proxying is the chat transition's to grant, and the generic one cannot", ctx do
    header = {"atproto-proxy", @target <> "#svc"}

    chat_conn = proxy(ctx.chat, "/xrpc/chat.bsky.convo.sendMessage", header)

    assert chat_conn.status == 200

    conn = proxy(ctx.generic, "/xrpc/chat.bsky.convo.sendMessage", header)
    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant rpc:chat.bsky.convo.sendMessage?aud=#{@target}%23svc"
  end

  test "a proxied call with no header is the 501, and a malformed header the 400", ctx do
    conn = proxy(ctx.generic, "/xrpc/app.bsky.feed.getTimeline", nil)

    assert conn.status == 501
    assert Client.json(conn)["error"] == "MethodNotImplemented"

    conn = proxy(ctx.generic, "/xrpc/app.bsky.feed.getTimeline", {"atproto-proxy", "not-a-did"})

    assert conn.status == 400
    assert Client.json(conn)["error"] == "InvalidRequest"
  end

  # The legacy session token is one scope that reaches everything.

  test "a legacy session token still writes records and reads its session", ctx do
    assert create_record(ctx.session_token, ctx.user.did, "app.bsky.feed.post").status == 200
    assert session_get(ctx.session_token).status == 200
  end

  # The app-password tiers over the plug: a non-privileged one is exactly
  # transition:generic, so every row the generic OAuth token answers 403 to
  # answers 403 to it, and a privileged one is the full grant, so it goes
  # where a password login goes.

  test "an app-password session writes records as its tier says", ctx do
    conn = create_record(ctx.app_token, ctx.user.did, "app.bsky.feed.post")

    assert conn.status == 200
    assert Client.json(conn)["uri"]

    assert create_record(ctx.app_privileged_token, ctx.user.did, "app.bsky.feed.post").status ==
             200
  end

  test "account management answers 403 to the non-privileged app-password tier", ctx do
    for path <- [
          "/xrpc/com.atproto.server.requestAccountDelete",
          "/xrpc/com.atproto.server.deactivateAccount"
        ] do
      conn = xrpc_post(path, %{}, ctx.app_token)

      assert conn.status == 403, path

      assert Client.json(conn)["message"] ==
               "this token does not grant account management (the atproto scope)"
    end

    assert xrpc_post("/xrpc/com.atproto.server.deactivateAccount", %{}, ctx.app_privileged_token).status ==
             200
  end

  test "identity answers 403 to the non-privileged app-password tier", ctx do
    conn = xrpc_get("/xrpc/com.atproto.identity.getRecommendedDidCredentials", ctx.app_token)

    assert conn.status == 403
    assert Client.json(conn)["message"] == "this token does not grant identity:handle"

    conn = xrpc_post("/xrpc/com.atproto.server.createInviteCodes", %{}, ctx.app_token)

    assert conn.status == 403

    assert Client.json(conn)["message"] ==
             "this token does not grant account management (the atproto scope)"
  end

  # fixtures and helpers

  # Each target answers {:ok, document}, the shape DidResolver passes on.
  defp documents do
    %{
      @target =>
        {:ok,
         %{
           "id" => @target,
           "service" => [
             %{
               "id" => @target <> "#bsky_appview",
               "type" => "BskyAppview",
               "serviceEndpoint" => "https://appview.example.com"
             },
             %{
               "id" => @target <> "#svc",
               "type" => "ChatService",
               "serviceEndpoint" => "https://chat.example.com"
             }
           ]
         }}
    }
  end

  defp oauth_token(user, scope) do
    key = Client.dpop_key()

    granted =
      Client.tokens_for(user, key, client_id: Client.client_id(scope: scope), scope: scope)

    %{
      key: key,
      token: Client.json(granted.token_conn)["access_token"],
      nonce: Client.nonce_from(granted.token_conn)
    }
  end

  # An app-password session token, minted the way the domain mints one: the
  # credential row decides the tier, the same path createSession runs.
  defp app_password_session(user, privileged) do
    {:ok, credential} = Accounts.create_app_password(user, "matrix" <> unique("tier"), privileged)

    row =
      Enum.find(Accounts.list_app_passwords(user.did), &(&1.name == credential.name)) ||
        flunk("the credential row is gone")

    {:ok, session} = Accounts.issue_session(user.did, app_password: row)
    session.access_jwt
  end

  defp challenge(conn) do
    conn |> get_resp_header("www-authenticate") |> List.first() || ""
  end

  defp session_get(sess) when is_binary(sess),
    do: xrpc_get("/xrpc/com.atproto.server.getSession", sess)

  defp session_get(%{} = sess) do
    authorized_get(sess, "/xrpc/com.atproto.server.getSession")
  end

  defp service_auth(sess, aud, lxm) when is_binary(sess) do
    query =
      [aud: aud, lxm: lxm]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{enc(value)}" end)

    xrpc_get("/xrpc/com.atproto.server.getServiceAuth?#{query}", sess)
  end

  defp service_auth(%{} = sess, aud, lxm) do
    query =
      [aud: aud, lxm: lxm]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("&", fn {key, value} -> "#{key}=#{enc(value)}" end)

    authorized_get(sess, "/xrpc/com.atproto.server.getServiceAuth?" <> query)
  end

  defp create_record(sess, repo, collection) when is_binary(sess) do
    xrpc_post("/xrpc/com.atproto.repo.createRecord", write_params(repo, collection), sess)
  end

  defp create_record(%{} = sess, repo, collection) do
    authorized_post(sess, "/xrpc/com.atproto.repo.createRecord", write_params(repo, collection))
  end

  defp write_params(repo, collection) do
    %{
      "repo" => repo,
      "collection" => collection,
      "record" => post_record("from the enforcement test")
    }
  end

  defp put_record(sess, repo, collection) do
    params = Map.merge(write_params(repo, collection), %{"rkey" => "enforcement"})

    authorized_post(sess, "/xrpc/com.atproto.repo.putRecord", params)
  end

  defp delete_record(sess, repo) do
    authorized_post(sess, "/xrpc/com.atproto.repo.deleteRecord", %{
      "repo" => repo,
      "collection" => "app.bsky.feed.post",
      "rkey" => "enforcement"
    })
  end

  defp apply_writes(sess, repo, writes) do
    authorized_post(sess, "/xrpc/com.atproto.repo.applyWrites", %{
      "repo" => repo,
      "writes" => writes
    })
  end

  defp upload_blob(sess, body, media_type) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("authorization", "DPoP " <> sess.token)
    |> put_req_header("dpop", proof(sess, "POST", "/xrpc/com.atproto.repo.uploadBlob"))
    |> put_req_header("content-type", media_type)
    |> dispatch(Endpoint, :post, "/xrpc/com.atproto.repo.uploadBlob", body)
  end

  defp proxy(sess, path, nil) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(sess, path)
    |> dispatch(Endpoint, :get, path, nil)
  end

  defp proxy(sess, path, header) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(sess, path)
    |> put_req_header(elem(header, 0), elem(header, 1))
    |> dispatch(Endpoint, :get, path, nil)
  end

  defp maybe_auth(conn, sess, _path) when is_binary(sess),
    do: put_req_header(conn, "authorization", "Bearer " <> sess)

  defp maybe_auth(conn, sess, path) do
    put_req_header(conn, "authorization", "DPoP " <> sess.token)
    |> put_req_header("dpop", proof(sess, "GET", path))
  end

  defp appview_proxy, do: {"atproto-proxy", @target <> "#bsky_appview"}

  defp authorized_get(sess, path) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "DPoP " <> sess.token)
    |> put_req_header("dpop", proof(sess, "GET", path))
    |> dispatch(Endpoint, :get, path, nil)
  end

  defp authorized_post(sess, path, body) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "DPoP " <> sess.token)
    |> put_req_header("dpop", proof(sess, "POST", path))
    |> dispatch(Endpoint, :post, path, body && JSON.encode!(body))
  end

  defp proof(sess, method, path) do
    Client.proof(sess.key, String.upcase(method), path, nonce: sess.nonce, ath: sess.token)
  end

  defp address do
    <<a, b, _::binary>> = :crypto.strong_rand_bytes(4)
    "203.0.#{a}.#{b}"
  end
end
