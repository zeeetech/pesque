defmodule PesqueWeb.OAuthResourceTest do
  @moduledoc """
  The resource-server half: an OAuth access token at an XRPC endpoint.

  A client that has just finished the authorization flow holds a DPoP-bound
  ES256 token and the key it is bound to. Every request it makes from there
  carries that token and a proof over that request, and this is where those
  two are checked together: the proof has to be for this URL, for this method,
  over this token, from the key the session was minted for.

  The legacy session token is in here too, because a change that accepts a
  second kind of token is exactly where the first one quietly stops working.
  Its tests are the same requests without a proof and without a scope.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.OAuth.Scopes
  alias PesqueWeb.OAuthCase, as: Client

  @session_path "/xrpc/com.atproto.server.getSession"
  @invite_path "/xrpc/com.atproto.server.createInviteCodes"
  @create_path "/xrpc/com.atproto.repo.createRecord"

  setup do
    user = create_account("alice")
    key = Client.dpop_key()
    granted = Client.tokens_for(user, key)
    body = Client.json(granted.token_conn)

    %{
      user: user,
      key: key,
      access_token: body["access_token"],
      nonce: Client.nonce_from(granted.token_conn),
      session_token: token(user)
    }
  end

  describe "an OAuth token reaches a protected endpoint" do
    test "with a proof over the request", ctx do
      conn = authorized(ctx, :get, @session_path)

      assert conn.status == 200
      assert Client.json(conn)["did"] == ctx.user.did
      assert Client.json(conn)["handle"] == ctx.user.handle
    end

    test "on a write route", ctx do
      conn = authorized(ctx, :post, @create_path, create_record(ctx.user, "from an oauth client"))

      assert conn.status == 200
      assert Client.json(conn)["uri"]
    end

    test "hands back a nonce so a client can keep going", ctx do
      assert Client.nonce_from(authorized(ctx, :get, @session_path))
    end
  end

  describe "a missing or wrong proof" do
    test "an OAuth token with no DPoP header at all is refused", ctx do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.access_token)
        |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 401
      assert Client.json(conn)["error"] == "AuthenticationRequired"
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "a proof for another URL is refused", ctx do
      conn = authorized(ctx, :get, @session_path, %{}, path: @create_path)

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
    end

    test "a proof for another method is refused", ctx do
      conn = authorized(ctx, :get, @session_path, %{}, method: "POST")

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
    end

    test "a proof over a different token is refused", ctx do
      other = Client.tokens_for(ctx.user, Client.dpop_key())
      other_token = Client.json(other.token_conn)["access_token"]

      conn = authorized(ctx, :get, @session_path, %{}, ath: other_token)

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
    end

    test "a malformed proof is refused rather than ignored", ctx do
      conn = authorized(ctx, :get, @session_path, %{}, proof: "not.a.jwt")

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
    end

    test "a proof from a key the session was not minted with is refused", ctx do
      # A proof that verifies perfectly against its own key, over the right
      # URL and method, for the right token. The only thing wrong with it is
      # that it is not the key this session is bound to.
      stranger = Client.dpop_key()

      conn =
        build_conn()
        |> put_req_header("authorization", "DPoP " <> ctx.access_token)
        |> put_req_header(
          "dpop",
          Client.proof(stranger, "GET", @session_path, nonce: ctx.nonce, ath: ctx.access_token)
        )
        |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_dpop_proof")
    end
  end

  describe "the use_dpop_nonce retry" do
    test "a proof with no nonce is answered with the nonce to retry with", ctx do
      conn = authorized(ctx, :get, @session_path, %{}, nonce: nil)

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="use_dpop_nonce")
      assert Client.nonce_from(conn)
    end

    test "retrying with that nonce is answered", ctx do
      first = authorized(ctx, :get, @session_path, %{}, nonce: nil)
      retry = authorized(ctx, :get, @session_path, %{}, nonce: Client.nonce_from(first))

      assert retry.status == 200
      assert Client.json(retry)["did"] == ctx.user.did
    end

    test "a stale nonce keeps asking for the live one", ctx do
      conn =
        authorized(ctx, :get, @session_path, %{}, nonce: "a-nonce-this-server-never-issued")

      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="use_dpop_nonce")
    end
  end

  describe "the token's scope" do
    setup ctx do
      # atproto on its own, without the compatibility scope. The default
      # client in these tests asks for both, and asking for both is asking
      # for the narrower of the two.
      key = Client.dpop_key()

      granted =
        Client.tokens_for(ctx.user, key,
          client_id: Client.client_id(scope: "atproto"),
          scope: "atproto"
        )

      Map.put(ctx, :atproto, %{
        key: key,
        access_token: Client.json(granted.token_conn)["access_token"],
        nonce: Client.nonce_from(granted.token_conn)
      })
    end

    test "a token granted only atproto reaches the account routes", ctx do
      conn =
        authorized(
          ctx,
          :post,
          @invite_path,
          %{"codeCount" => 1, "useCount" => 1},
          token: ctx.atproto.access_token,
          key: ctx.atproto.key,
          nonce: ctx.atproto.nonce
        )

      assert conn.status == 200
      assert length(Client.json(conn)["codes"]) == 1
    end

    test "a token also granted transition:generic cannot", ctx do
      # transition:generic is the app-password equivalent, and an app password
      # does not manage accounts. Asking for it has to cost something, or it is
      # a scope that means nothing.
      conn =
        authorized(ctx, :post, @invite_path, %{"codeCount" => 1}, token: ctx.access_token)

      assert conn.status == 403
      assert Client.json(conn)["error"] == "InsufficientScope"
      assert challenge(conn) =~ ~s(error="insufficient_scope")
    end

    test "the same token still reaches everything the narrow scope allows", ctx do
      assert authorized(ctx, :get, @session_path, %{}, token: ctx.access_token).status == 200

      assert authorized(
               ctx,
               :post,
               @create_path,
               create_record(ctx.user, "narrow but allowed")
             ).status == 200
    end

    test "the mapping is written down in one place" do
      assert :read in Scopes.permissions("atproto")
      assert :write in Scopes.permissions("atproto")
      assert :account in Scopes.permissions("atproto")

      assert :read in Scopes.permissions("transition:generic")
      assert :write in Scopes.permissions("transition:generic")
      refute :account in Scopes.permissions("transition:generic")

      assert Scopes.permissions("atproto transition:generic") == [:read, :write]
      assert Scopes.permissions("") == []
      assert Scopes.permissions("transition:email") == []
    end
  end

  describe "a legacy session token" do
    test "still reaches an account route with no proof", ctx do
      conn =
        build_conn()
        |> authorization(ctx.session_token)
        |> post_json(@invite_path, %{"codeCount" => 1, "useCount" => 1})

      assert conn.status == 200
      assert length(Client.json(conn)["codes"]) == 1
    end

    test "still reaches a read route with no proof", ctx do
      conn =
        build_conn()
        |> authorization(ctx.session_token)
        |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 200
      assert Client.json(conn)["did"] == ctx.user.did
    end

    test "still reaches a write route with no proof", ctx do
      conn =
        build_conn()
        |> authorization(ctx.session_token)
        |> post_json(@create_path, create_record(ctx.user, "from a session token"))

      assert conn.status == 200
    end

    test "is refused exactly as before with no token" do
      conn = build_conn() |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 401
      assert Client.json(conn)["error"] == "AuthenticationRequired"
      assert Client.json(conn)["message"] == "a valid access token is required"
    end

    test "is refused exactly as before with a broken token", ctx do
      conn =
        build_conn()
        |> authorization(ctx.session_token <> "tampered")
        |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 401
      assert Client.json(conn)["error"] == "AuthenticationRequired"
      assert Client.json(conn)["message"] == "a valid access token is required"
    end

    test "an OAuth token is not verified as a session token", ctx do
      # Both verifiers run a signature check the other cannot pass, but the
      # point is the other direction: a token presented as HS256 is refused
      # against the legacy secret rather than being given a second chance.
      conn =
        build_conn()
        |> authorization("Bearer " <> String.replace(ctx.access_token, ~r/\.[^.]+$/, "AAAA"))
        |> dispatch(Endpoint, :get, @session_path)

      assert conn.status == 401
    end
  end

  defp challenge(conn) do
    conn |> get_resp_header("www-authenticate") |> List.first() || ""
  end

  defp create_record(user, text) do
    %{
      "repo" => user.did,
      "collection" => collection(),
      "record" => post_record(text)
    }
  end

  defp authorization(conn, bearer) do
    put_req_header(conn, "authorization", "Bearer " <> bearer)
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> dispatch(Endpoint, :post, path, JSON.encode!(params))
  end

  # Every request here claims its own address, for the same reason the OAuth
  # client does: the rate limiter counts by address and its table outlives the
  # test transaction.
  defp authorized(ctx, method, path, body \\ %{}, opts \\ []) do
    key = Keyword.get(opts, :key, ctx.key)
    access = Keyword.get(opts, :token, ctx.access_token)
    proof = Keyword.get_lazy(opts, :proof, fn -> proof(ctx, key, method, path, access, opts) end)

    build_conn()
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "DPoP " <> access)
    |> put_req_header("dpop", proof)
    |> dispatch(Endpoint, method, path, JSON.encode!(body))
  end

  defp proof(ctx, key, method, path, access, opts) do
    Client.proof(
      key,
      Keyword.get(opts, :method, method |> Atom.to_string() |> String.upcase()),
      Keyword.get(opts, :path, path),
      nonce: Keyword.get(opts, :nonce, ctx.nonce),
      ath: Keyword.get(opts, :ath, access)
    )
  end

  defp address do
    <<a, b, _::binary>> = :crypto.strong_rand_bytes(4)
    "203.0.#{a}.#{b}"
  end
end
