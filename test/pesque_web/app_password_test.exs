defmodule PesqueWeb.AppPasswordTest do
  @moduledoc """
  The app-password endpoints over real requests, and the tier matrix they sit
  in: a non-privileged app-password session is exactly the transition:generic
  grant set, a privileged one is the full grant minus the ability to create
  app passwords, and OAuth tokens are refused on all three endpoints however
  broad their grants.

  The fixture tokens are minted through createSession over HTTP with the
  credentials create_app_password/3 answered, so the scope claim is produced
  by the real path.
  """

  use PesqueWeb.ConnCase, async: false

  alias PesqueWeb.OAuthCase, as: Client

  @password "hunter2hunter2"
  @request_id "0123456789abcdef0123456789abcdef"

  defmodule Directory do
    def resolve(did) do
      documents = :persistent_term.get(:app_password_documents, %{})
      Map.get(documents, did, {:error, :not_found})
    end
  end

  defmodule Fetch do
    def request(_uri, _method, _headers, _body, _opts) do
      {:ok, 200, [{"content-type", "application/json"}], ~s({"ok":true})}
    end
  end

  @target "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  setup do
    user = create_account("alice")

    # The proxy needs a target that resolves and answers.
    :persistent_term.put(:app_password_documents, documents())
    Application.put_env(:pesque, :did_resolver_directory, Directory)
    Application.put_env(:pesque, :entryway_fetch, Fetch)

    on_exit(fn ->
      :persistent_term.erase(:app_password_documents)
      Application.delete_env(:pesque, :did_resolver_directory)
      Application.delete_env(:pesque, :entryway_fetch)
    end)

    {:ok, app_credential} = Accounts.create_app_password(user, "test-app", false)
    {:ok, priv_credential} = Accounts.create_app_password(user, "trusted", true)

    %{
      user: user,
      app_password: app_credential,
      priv_password: priv_credential,
      password_login: login(user.handle, @password)["accessJwt"],
      app_token: login(user.handle, app_credential.password)["accessJwt"],
      app_refresh: login(user.handle, app_credential.password)["refreshJwt"],
      priv_token: login(user.handle, priv_credential.password)["accessJwt"]
    }
  end

  # The happy path: the credential kind that is allowed to mint one.

  test "createAppPassword answers the password once, with the lexicon body", %{
    password_login: token
  } do
    conn = post_xrpc("/xrpc/com.atproto.server.createAppPassword", %{"name" => "new-app"}, token)

    assert conn.status == 200

    body = JSON.decode!(conn.resp_body)
    assert body["name"] == "new-app"
    assert body["password"] =~ ~r/\A[a-z2-7]{4}(-[a-z2-7]{4}){3}\z/
    assert body["privileged"] == false
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(body["createdAt"])

    # A duplicate name is a real 400, not an unhandled DB error.
    conn = post_xrpc("/xrpc/com.atproto.server.createAppPassword", %{"name" => "new-app"}, token)

    assert conn.status == 400

    assert JSON.decode!(conn.resp_body)["message"] ==
             "an app password with that name already exists"

    # privileged rides only as a literal true: a string "true" is not a
    # promise this server makes.
    conn =
      post_xrpc(
        "/xrpc/com.atproto.server.createAppPassword",
        %{"name" => "strung", "privileged" => "true"},
        token
      )

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["privileged"] == false
  end

  test "listAppPasswords answers names and privileges, never the passwords", %{
    user: user,
    password_login: token
  } do
    {:ok, _} = Accounts.create_app_password(user, "listed", true)

    conn = get_xrpc("/xrpc/com.atproto.server.listAppPasswords", token)

    assert conn.status == 200

    passwords = JSON.decode!(conn.resp_body)["passwords"]
    assert %{"name" => "listed", "privileged" => true, "createdAt" => _} = hd(passwords)
    refute Enum.any?(passwords, &Map.has_key?(&1, "password"))
  end

  test "revokeAppPassword is idempotent and answers an empty object", %{password_login: token} do
    conn =
      post_xrpc("/xrpc/com.atproto.server.revokeAppPassword", %{"name" => "never-existed"}, token)

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{}
  end

  # The endpoint matrix, one row at a time.

  test "getSession: the reduced tier never sees the email", ctx do
    conn = get_xrpc("/xrpc/com.atproto.server.getSession", ctx.app_token)

    assert conn.status == 200
    refute Map.has_key?(JSON.decode!(conn.resp_body), "email")

    conn = get_xrpc("/xrpc/com.atproto.server.getSession", ctx.priv_token)
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["email"]
  end

  test "getServiceAuth: non-chat lxms pass the reduced tier, chat ones do not", ctx do
    conn =
      get_xrpc(
        "/xrpc/com.atproto.server.getServiceAuth?aud=did:web:relay.example.com&lxm=app.bsky.feed.getFeedSkeleton",
        ctx.app_token
      )

    assert conn.status == 200

    conn =
      get_xrpc(
        "/xrpc/com.atproto.server.getServiceAuth?aud=did:web:chat.example.com&lxm=chat.bsky.convo.getMessages",
        ctx.app_token
      )

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    conn =
      get_xrpc(
        "/xrpc/com.atproto.server.getServiceAuth?aud=did:web:chat.example.com&lxm=chat.bsky.convo.getMessages",
        ctx.priv_token
      )

    assert conn.status == 200
  end

  test "the proxy catch-all: non-chat lxms pass the reduced tier, chat does not", ctx do
    header = @target <> "#svc"

    conn =
      build_conn()
      |> put_req_header("x-request-id", @request_id)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> ctx.app_token)
      |> put_req_header("atproto-proxy", header)
      |> dispatch(Endpoint, :get, "/xrpc/app.bsky.feed.getTimeline", nil)

    assert conn.status == 200

    conn =
      build_conn()
      |> put_req_header("x-request-id", @request_id)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> ctx.app_token)
      |> put_req_header("atproto-proxy", header)
      |> dispatch(Endpoint, :get, "/xrpc/chat.bsky.convo.getMessages", nil)

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"
  end

  test "repo writes and blob upload pass the reduced tier", ctx do
    conn =
      post_xrpc(
        "/xrpc/com.atproto.repo.createRecord",
        %{
          "repo" => ctx.user.did,
          "collection" => "app.bsky.feed.post",
          "record" => post_record("from an app password")
        },
        ctx.app_token
      )

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["uri"]

    conn =
      build_conn()
      |> put_req_header("x-request-id", @request_id)
      |> put_req_header("content-type", "image/jpeg")
      |> put_req_header("authorization", "Bearer " <> ctx.app_token)
      |> dispatch(Endpoint, :post, "/xrpc/com.atproto.repo.uploadBlob", "jpeg-bytes")

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["blob"]["ref"]["$link"]
  end

  test "preferences pass the reduced tier", ctx do
    conn = get_xrpc("/xrpc/app.bsky.actor.getPreferences", ctx.app_token)
    assert conn.status == 200

    conn = post_xrpc("/xrpc/app.bsky.actor.putPreferences", %{"preferences" => []}, ctx.app_token)
    assert conn.status == 200
  end

  test "listMissingBlobs passes the reduced tier", ctx do
    conn = get_xrpc("/xrpc/com.atproto.repo.listMissingBlobs", ctx.app_token)
    assert conn.status == 200
  end

  test "importRepo answers 403 to the reduced tier and reaches the controller for the privileged one",
       ctx do
    conn = post_xrpc("/xrpc/com.atproto.repo.importRepo", %{}, ctx.app_token)

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    conn = post_xrpc("/xrpc/com.atproto.repo.importRepo", %{}, ctx.priv_token)

    assert conn.status == 400
    assert error_name(conn) == "InvalidRequest"
  end

  test "identity:handle endpoints answer 403 to the reduced tier", ctx do
    conn = get_xrpc("/xrpc/com.atproto.identity.getRecommendedDidCredentials", ctx.app_token)

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    conn =
      post_xrpc(
        "/xrpc/com.atproto.identity.updateHandle",
        %{"handle" => "other.example.com"},
        ctx.app_token
      )

    assert conn.status == 403

    # The privileged tier reaches them, exactly like a password login.
    conn = get_xrpc("/xrpc/com.atproto.identity.getRecommendedDidCredentials", ctx.priv_token)
    assert conn.status == 200

    conn = post_xrpc("/xrpc/com.atproto.identity.updateHandle", %{}, ctx.priv_token)

    assert conn.status == 400
    assert error_name(conn) == "InvalidRequest"
  end

  test "identity:* endpoints answer 403 to the reduced tier and reach the controller for the privileged one",
       ctx do
    for path <- [
          "/xrpc/com.atproto.identity.submitPlcOperation",
          "/xrpc/com.atproto.identity.requestPlcOperationSignature",
          "/xrpc/com.atproto.identity.signPlcOperation"
        ] do
      conn = post_xrpc(path, %{}, ctx.app_token)

      assert conn.status == 403, path
      assert error_name(conn) == "InsufficientScope"
    end

    # This account is did:web, so the controller, not the plug, is what
    # answers the privileged tier.
    for path <- [
          "/xrpc/com.atproto.identity.submitPlcOperation",
          "/xrpc/com.atproto.identity.requestPlcOperationSignature",
          "/xrpc/com.atproto.identity.signPlcOperation"
        ] do
      conn = post_xrpc(path, %{}, ctx.priv_token)

      assert conn.status == 400, path
      assert error_name(conn) == "InvalidRequest"
    end
  end

  test "account management answers 403 to the reduced tier", ctx do
    for path <- [
          "/xrpc/com.atproto.server.requestAccountDelete",
          "/xrpc/com.atproto.server.deleteAccount",
          "/xrpc/com.atproto.server.deactivateAccount",
          "/xrpc/com.atproto.server.activateAccount"
        ] do
      conn = post_xrpc(path, %{}, ctx.app_token)

      assert conn.status == 403, path
      assert error_name(conn) == "InsufficientScope"

      assert JSON.decode!(conn.resp_body)["message"] ==
               "this token does not grant account management (the atproto scope)"
    end
  end

  test "the privileged tier passes account management, deactivate and activate included", _ctx do
    scratch = create_account("scratch")
    {:ok, scratch_credential} = Accounts.create_app_password(scratch, "scratch-app", true)
    priv = login(scratch.handle, scratch_credential.password)["accessJwt"]

    conn = post_xrpc("/xrpc/com.atproto.server.deactivateAccount", %{}, priv)
    assert conn.status == 200

    conn = post_xrpc("/xrpc/com.atproto.server.activateAccount", %{}, priv)
    assert conn.status == 200

    conn = post_xrpc("/xrpc/com.atproto.server.requestAccountDelete", %{}, priv)
    assert conn.status == 200

    # deleteAccount still demands the account password and a deletion token
    # in the controller: passing the plug is not passing the flow.
    conn = post_xrpc("/xrpc/com.atproto.server.deleteAccount", %{}, priv)
    assert conn.status == 400
    assert error_name(conn) == "InvalidRequest"
  end

  test "createInviteCodes: the reduced tier is 403 even on the operator list", ctx do
    Application.put_env(:pesque, :admin_dids, [ctx.user.did])

    on_exit(fn -> Application.delete_env(:pesque, :admin_dids) end)

    conn = post_xrpc("/xrpc/com.atproto.server.createInviteCodes", %{}, ctx.app_token)

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    # The privileged tier passes the auth plug; the admin plug is next in the
    # pipeline and this test's account is on the list, so the controller
    # answers.
    conn =
      post_xrpc(
        "/xrpc/com.atproto.server.createInviteCodes",
        %{"codeCount" => 1, "useCount" => 1},
        ctx.priv_token
      )

    assert conn.status == 200
  end

  test "createAppPassword is refused to every session but a password login", ctx do
    conn =
      post_xrpc("/xrpc/com.atproto.server.createAppPassword", %{"name" => "no"}, ctx.app_token)

    assert conn.status == 403

    assert JSON.decode!(conn.resp_body)["message"] =~
             "app passwords are created with the account password"

    conn =
      post_xrpc("/xrpc/com.atproto.server.createAppPassword", %{"name" => "no"}, ctx.priv_token)

    assert conn.status == 403

    assert JSON.decode!(conn.resp_body)["message"] =~
             "app passwords are created with the account password"

    conn =
      post_xrpc(
        "/xrpc/com.atproto.server.createAppPassword",
        %{"name" => "yes"},
        ctx.password_login
      )

    assert conn.status == 200
  end

  test "listAppPasswords and revokeAppPassword: reduced 403, privileged and password login pass",
       ctx do
    conn = get_xrpc("/xrpc/com.atproto.server.listAppPasswords", ctx.app_token)
    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    conn =
      post_xrpc("/xrpc/com.atproto.server.revokeAppPassword", %{"name" => "n"}, ctx.app_token)

    assert conn.status == 403
    assert error_name(conn) == "InsufficientScope"

    conn = get_xrpc("/xrpc/com.atproto.server.listAppPasswords", ctx.priv_token)
    assert conn.status == 200

    conn =
      post_xrpc("/xrpc/com.atproto.server.revokeAppPassword", %{"name" => "n"}, ctx.priv_token)

    assert conn.status == 200

    conn = get_xrpc("/xrpc/com.atproto.server.listAppPasswords", ctx.password_login)
    assert conn.status == 200
  end

  # The tier travels in the scope claim, produced by the real login path.

  test "createSession with an app password carries the tier, and rotation keeps it", ctx do
    assert scope_claim(ctx.app_token) == "com.atproto.appPass"
    assert scope_claim(ctx.priv_token) == "com.atproto.appPassPrivileged"

    # Email omission at login for the non-privileged tier.
    refute Map.has_key?(login(ctx.user.handle, ctx.app_password.password), "email")

    # Privileged logins see it, as a password login does.
    assert login(ctx.user.handle, ctx.priv_password.password)["email"]

    conn = refresh_with(ctx.app_refresh)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert scope_claim(body["accessJwt"]) == "com.atproto.appPass"

    # Rotation is single use: the spent token is dead.
    assert refresh_with(ctx.app_refresh).status == 401
  end

  test "revoking an app password kills its sessions and its login", ctx do
    conn =
      post_xrpc(
        "/xrpc/com.atproto.server.revokeAppPassword",
        %{"name" => "test-app"},
        ctx.password_login
      )

    assert conn.status == 200

    assert refresh_with(ctx.app_refresh).status == 401

    conn = login_conn(ctx.user.handle, ctx.app_password.password)
    assert conn.status == 401

    # A password login on the same account still works: only the credential
    # and its sessions went.
    conn = login_conn(ctx.user.handle, @password)
    assert conn.status == 200
  end

  test "an OAuth token is refused on all three endpoints, however broad its grants", ctx do
    key = Client.dpop_key()

    granted =
      Client.tokens_for(ctx.user, key,
        client_id: Client.client_id(scope: "atproto"),
        scope: "atproto"
      )

    token = Client.json(granted.token_conn)["access_token"]
    nonce = Client.nonce_from(granted.token_conn)

    for {method, path, body} <- [
          {:post, "/xrpc/com.atproto.server.createAppPassword", %{"name" => "n"}},
          {:get, "/xrpc/com.atproto.server.listAppPasswords", nil},
          {:post, "/xrpc/com.atproto.server.revokeAppPassword", %{"name" => "n"}}
        ] do
      conn = oauth_request(key, method, path, body, token, nonce)

      assert conn.status == 403, path
      assert error_name(conn) == "InsufficientScope"
      assert JSON.decode!(conn.resp_body)["message"] =~ "OAuth tokens do not manage app passwords"
    end
  end

  # The escalation pin: the OAuth authorize page keeps calling
  # verify_login/2, the account password only. An app password that approved
  # an OAuth request would hand a non-privileged credential a full atproto
  # token, which is the app-password reduction undone through the front door.
  test "the OAuth authorize page refuses an app password and the request survives", ctx do
    key = Client.dpop_key()
    pushed = Client.par(key)

    conn =
      Client.decide(
        pushed.request_uri,
        pushed.params["client_id"],
        ctx.user.handle,
        "approve",
        ctx.app_password.password
      )

    assert conn.status == 401
    assert Client.error(conn) == "access_denied"

    # The request was not consumed: the account password still approves it.
    retry = Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle)
    assert retry.status == 302
  end

  # helpers

  defp documents do
    %{
      @target =>
        {:ok,
         %{
           "id" => @target,
           "service" => [
             %{
               "id" => @target <> "#svc",
               "type" => "ChatService",
               "serviceEndpoint" => "https://chat.example.com"
             }
           ]
         }}
    }
  end

  defp login(identifier, password) do
    conn = login_conn(identifier, password)
    assert conn.status == 200, "login answered #{conn.status}"
    JSON.decode!(conn.resp_body)
  end

  defp login_conn(identifier, password) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-forwarded-for", address())
    |> dispatch(
      Endpoint,
      :post,
      "/xrpc/com.atproto.server.createSession",
      JSON.encode!(%{"identifier" => identifier, "password" => password})
    )
  end

  defp refresh_with(refresh_jwt) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("authorization", "Bearer " <> refresh_jwt)
    |> dispatch(Endpoint, :post, "/xrpc/com.atproto.server.refreshSession", nil)
  end

  defp post_xrpc(path, params, token) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(Endpoint, :post, path, JSON.encode!(params))
  end

  defp get_xrpc(path, token) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(Endpoint, :get, path, nil)
  end

  defp oauth_request(key, method, path, body, token, nonce) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "DPoP " <> token)
    |> put_req_header(
      "dpop",
      Client.proof(key, String.upcase(Atom.to_string(method)), path, nonce: nonce, ath: token)
    )
    |> dispatch(Endpoint, method, path, body && JSON.encode!(body))
  end

  defp scope_claim(jwt) do
    [_header, payload, _sig] = String.split(jwt, ".")
    %{"scope" => scope} = payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
    scope
  end

  defp error_name(conn), do: JSON.decode!(conn.resp_body)["error"]

  defp address do
    <<a, b, _::binary>> = :crypto.strong_rand_bytes(4)
    "203.0.#{a}.#{b}"
  end
end
