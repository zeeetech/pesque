defmodule PesqueWeb.OAuth.PermissionSetsFlowTest do
  @moduledoc """
  The `include:` half of the OAuth flow over real requests.

  A set PAR cannot resolve fails the push with its NSID named; one PAR can
  resolve shows its own words on the consent page, folded until asked for, and
  issues a token whose stored grants are the set's expansion; unchecking the
  set narrows to atproto and nothing else; and a refresh recomputes the
  expansion while the access token it replaces keeps the one it was issued
  with, because those grants are fixed for the token's life.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.OAuth
  alias Pesque.OAuth.Grants
  alias Pesque.OAuth.Permission
  alias Pesque.OAuth.PermissionSets.Cache
  alias PesqueWeb.OAuthCase, as: Client

  @aud "did:web:api.bsky.app%23appview"
  @full_app "app.bsky.authFullApp"

  defmodule FakeAggregator do
    @moduledoc "The aggregator a test stands in for: answers it was given, nothing else."

    @behaviour Pesque.Lexicon.Resolver

    def resolve(nsid) do
      :persistent_term.get(:permission_sets_flow_answers, %{})
      |> Map.get(nsid, {:error, :not_found})
    end
  end

  setup do
    %{user: create_account("alice"), key: Client.dpop_key()}
  end

  test "PAR refuses an include of a set it cannot resolve, naming the set", ctx do
    scope = "atproto include:app.example.unresolvable.set"

    conn = Client.par_accepted(ctx.key, par_params(scope))

    assert conn.status == 400
    body = Client.json(conn)
    assert body["error"] == "invalid_scope"
    assert body["error_description"] =~ "app.example.unresolvable.set"
  end

  test "the consent page shows the set's title and detail, with the expansion folded away", ctx do
    scope = "atproto include:#{@full_app}?aud=#{@aud}"
    pushed = Client.par(ctx.key, client_id: Client.client_id(scope: scope), scope: scope)

    page = authorize_page(pushed, nil)

    assert page.status == 200
    assert page.resp_body =~ "Full Bluesky Social App Permissions"
    assert page.resp_body =~ "Manage all public content and interactions"
    assert page.resp_body =~ "<details>"
    assert page.resp_body =~ "What this set grants"
    assert page.resp_body =~ "app.bsky.feed.post"

    # The set narrows all-or-nothing: one checkbox, holding the include.
    assert page.resp_body =~ "value=\"include:#{@full_app}?aud=#{@aud}\""
  end

  test "the consent page answers in the language the browser asked for first", ctx do
    scope = "atproto include:chat.bsky.authFullChatClient?aud=#{@aud}"
    pushed = Client.par(ctx.key, client_id: Client.client_id(scope: scope), scope: scope)

    # The chat set carries one localized detail, keyed "en". The primary tag
    # that matches it is shown; one that does not match falls to the base
    # field.
    assert authorize_page(pushed, "en").resp_body =~ "All Chat Conversations"

    assert authorize_page(pushed, "en-GB,en;q=0.9").resp_body =~
             "Control of all chat conversations"
  end

  test "the flow mints a token whose grants are the set's expansion", ctx do
    scope = "atproto include:#{@full_app}?aud=#{@aud}"

    granted =
      Client.tokens_for(ctx.user, ctx.key,
        client_id: Client.client_id(scope: scope),
        scope: scope
      )

    assert granted.token_conn.status == 200
    body = Client.json(granted.token_conn)
    assert body["scope"] == scope

    # The expansion, stored and read back: the repo member with all of its
    # actions, and the rpc member wearing the include's audience.
    {:ok, claims} = OAuth.verify_access_token(body["access_token"])
    assert claims["scope"] == scope
    grants = Grants.parse(claims["grants"])

    assert Enum.any?(grants, fn
             %Permission{resource: :repo, action: [:create, :update, :delete], collection: c} ->
               "app.bsky.feed.post" in c

             _other ->
               false
           end)

    assert Enum.any?(grants, fn
             %Permission{resource: :rpc, lxm: lxms} -> "app.bsky.actor.getPreferences" in lxms
             _other -> false
           end)

    rpc = Enum.find(grants, &(&1.resource == :rpc))
    assert rpc.aud == "did:web:api.bsky.app#appview"

    # And the grants hold where it matters: the expanded repo member writes.
    sess = %{
      key: ctx.key,
      token: body["access_token"],
      nonce: Client.nonce_from(granted.token_conn)
    }

    conn =
      authorized_post(sess, "/xrpc/com.atproto.repo.createRecord", %{
        "repo" => ctx.user.did,
        "collection" => "app.bsky.feed.post",
        "record" => post_record()
      })

    assert conn.status == 200
  end

  test "unchecking the set grants atproto and nothing else", ctx do
    scope = "atproto include:#{@full_app}?aud=#{@aud}"
    client_id = Client.client_id(scope: scope)

    pushed = Client.par(ctx.key, client_id: client_id, scope: scope)
    conn = Client.decide_scopes(pushed.request_uri, client_id, ctx.user.handle, [])
    assert conn.status == 302

    exchanged =
      Client.exchange(
        ctx.key,
        %{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => returned_code(conn),
          "code_verifier" => pushed.verifier,
          "redirect_uri" => pushed.params["redirect_uri"]
        },
        nonce: pushed.nonce
      )

    assert exchanged.status == 200
    assert Client.json(exchanged)["scope"] == "atproto"

    {:ok, claims} = OAuth.verify_access_token(Client.json(exchanged)["access_token"])
    assert claims["grants"] == "atproto"
  end

  test "a set that stopped being resolvable fails the decision, not the exchange", ctx do
    {set, scope, client_id} = synthetic_scope()

    resolve_with(%{
      set => {:ok, set_document(set, [repo_member(["app.example.post"], ["create"])])}
    })

    pushed = Client.par(ctx.key, client_id: client_id, scope: scope)

    # Then it is gone: not in the registry, not cached, not fetchable. The
    # decision cannot grant what nobody can read any more.
    resolve_with(%{})
    :ets.delete(:pesque_permission_sets, set)
    Application.delete_env(:pesque, :lexicon_resolver)

    conn = Client.decide(pushed.request_uri, client_id, ctx.user.handle)

    assert conn.status == 400
    body = Client.json(conn)
    assert body["error"] == "invalid_scope"
    assert body["error_description"] =~ set
  end

  test "a set that stopped being resolvable before the exchange fails the token request", ctx do
    {set, scope, client_id} = synthetic_scope()

    resolve_with(%{
      set => {:ok, set_document(set, [repo_member(["app.example.post"], ["create"])])}
    })

    granted = Client.approve(ctx.user, ctx.key, client_id: client_id, scope: scope)

    resolve_with(%{})
    :ets.delete(:pesque_permission_sets, set)
    Application.delete_env(:pesque, :lexicon_resolver)

    exchanged =
      Client.exchange(
        ctx.key,
        %{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => granted.code,
          "code_verifier" => granted.verifier,
          "redirect_uri" => granted.redirect_uri
        },
        nonce: granted.nonce
      )

    assert exchanged.status == 400
    body = Client.json(exchanged)
    assert body["error"] == "invalid_scope"
    assert body["error_description"] =~ set
  end

  test "a refresh recomputes the expansion; the access token keeps its stored grants", ctx do
    {set, scope, client_id} = synthetic_scope("refreshable")
    narrow = set_document(set, [repo_member(["app.example.post"], ["create"])])
    wider = set_document(set, [repo_member(["app.example.post", "app.example.like"], ["create"])])

    resolve_with(%{set => {:ok, narrow}})

    granted = Client.tokens_for(ctx.user, ctx.key, client_id: client_id, scope: scope)
    tokens = Client.json(granted.token_conn)
    {:ok, claims} = OAuth.verify_access_token(tokens["access_token"])
    assert claims["grants"] == "repo:app.example.post?action=create"

    # The set changed and its cache entry went stale: the refresh resolves it
    # anew and the wider answer is what the new pair carries.
    stale_ms = System.system_time(:millisecond) - 25 * 60 * 60 * 1000
    Cache.put(set, narrow, stale_ms)
    resolve_with(%{set => {:ok, wider}})

    conn =
      Client.token(
        ctx.key,
        %{
          "grant_type" => "refresh_token",
          "client_id" => client_id,
          "refresh_token" => tokens["refresh_token"]
        },
        granted.nonce
      )

    assert conn.status == 200
    rotated = Client.json(conn)

    {:ok, rotated_claims} = OAuth.verify_access_token(rotated["access_token"])

    assert rotated_claims["grants"] ==
             "repo?collection=app.example.post&collection=app.example.like&action=create"

    # The access token minted before the change is not recomputed: what it
    # was issued with is what it holds, for its whole life.
    {:ok, claims_again} = OAuth.verify_access_token(tokens["access_token"])
    assert claims_again["grants"] == "repo:app.example.post?action=create"
  end

  # The helpers.

  defp synthetic_scope(suffix \\ "vanishing") do
    set = "app.example." <> suffix <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    scope = "atproto include:#{set}?aud=did:web:api.example.com%23svc"

    {set, scope, Client.client_id(scope: scope)}
  end

  defp resolve_with(answers) do
    Application.put_env(:pesque, :lexicon_resolver, FakeAggregator)
    :persistent_term.put(:permission_sets_flow_answers, answers)

    on_exit(fn ->
      Application.delete_env(:pesque, :lexicon_resolver)
      :persistent_term.erase(:permission_sets_flow_answers)
    end)

    :ok
  end

  defp par_params(scope) do
    code = Client.pkce()

    %{
      "client_id" => Client.client_id(scope: scope),
      "response_type" => "code",
      "redirect_uri" => Client.redirect_uri(),
      "scope" => scope,
      "state" => Client.state(),
      "code_challenge" => code.challenge,
      "code_challenge_method" => "S256"
    }
  end

  defp authorize_page(pushed, lang) do
    conn = build_conn()
    conn = if lang, do: put_req_header(conn, "accept-language", lang), else: conn

    query =
      URI.encode_query(%{
        "client_id" => pushed.params["client_id"],
        "request_uri" => pushed.request_uri
      })

    dispatch(conn, Endpoint, :get, "/oauth/authorize?" <> query)
  end

  defp returned_code(conn) do
    conn
    |> get_resp_header("location")
    |> hd()
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.fetch!("code")
  end

  defp authorized_post(sess, path, params) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "DPoP " <> sess.token)
    |> put_req_header("dpop", proof(sess, "POST", path))
    |> dispatch(Endpoint, :post, path, JSON.encode!(params))
  end

  defp proof(sess, method, path) do
    Client.proof(sess.key, method, path, nonce: sess.nonce, ath: sess.token)
  end

  defp post_record do
    %{
      "$type" => "app.bsky.feed.post",
      "text" => "written by the set's expansion",
      "createdAt" => "2026-01-01T00:00:00.000Z"
    }
  end

  defp set_document(id, permissions) do
    %{
      "lexicon" => 1,
      "id" => id,
      "defs" => %{
        "main" => %{
          "type" => "permission-set",
          "title" => "Flow set",
          "detail" => "Written by the test, for the test",
          "permissions" => permissions
        }
      }
    }
  end

  defp repo_member(collections, actions) do
    %{
      "type" => "permission",
      "resource" => "repo",
      "collection" => collections,
      "action" => actions
    }
  end
end
