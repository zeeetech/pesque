defmodule PesqueWeb.OAuth.FlowTest do
  @moduledoc """
  The whole authorization flow over real requests, and every way it must fail.

  The order is the order a client takes: PAR, the login page, approval, the
  code exchange, refresh, revocation. Each refusal is asserted on the OAuth
  error code rather than the status, because the code is what a client
  branches on, and the status is usually the same 400 for half of them.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.OAuth
  alias PesqueWeb.OAuthCase, as: Client

  setup do
    %{
      user: create_account("alice"),
      key: Client.dpop_key()
    }
  end

  describe "the happy path" do
    test "PAR, authorize and the code exchange", ctx do
      pushed = Client.par(ctx.key)

      assert String.starts_with?(pushed.request_uri, "urn:ietf:params:oauth:request_uri:")
      assert JSON.decode!(pushed.conn.resp_body)["expires_in"] == OAuth.par_ttl_seconds()

      page = Client.authorize_page(pushed.request_uri, pushed.params["client_id"])
      assert page.status == 200
      assert page.resp_body =~ "Authorize"
      # The client_id is attacker-chosen text rendered into a page, so it is
      # escaped on the way out. What matters is that it is shown verbatim
      # after unescaping, and never as live markup.
      assert page.resp_body =~ "&amp;scope="
      refute page.resp_body =~ pushed.params["client_id"]

      granted = Client.approve(ctx.user, ctx.key)

      assert granted.code
      # approve/2 runs its own PAR, so its state is the one that comes back.
      assert granted.returned["state"] == granted.params["state"]
      assert granted.params["state"] != pushed.params["state"]
      assert granted.returned["iss"] == Pesque.base_url()
      assert String.starts_with?(granted.location, pushed.params["redirect_uri"])

      conn =
        Client.exchange(
          ctx.key,
          %{
            "grant_type" => "authorization_code",
            "client_id" => granted.client_id,
            "code" => granted.code,
            "code_verifier" => granted.verifier,
            "redirect_uri" => granted.redirect_uri
          },
          nonce: granted.nonce
        )

      body = Client.json(conn)
      assert conn.status == 200
      assert body["token_type"] == "DPoP"
      assert body["scope"] == "atproto transition:generic"
      assert body["sub"] == ctx.user.did
      assert body["refresh_token"]
      assert body["access_token"]
      assert body["expires_in"] == OAuth.access_ttl_seconds()

      # The access token verifies against the published key and names the DPoP
      # key the session was created with.
      assert {:ok, claims} = OAuth.verify_access_token(body["access_token"])
      assert claims["sub"] == ctx.user.did
      assert OAuth.jkt(claims) == Client.dpop_key_jkt(ctx.key)
    end

    test "a refresh rotates the pair and answers a new refresh token", ctx do
      granted = Client.approve(ctx.user, ctx.key)
      tokens = tokens_for(ctx, granted)

      conn =
        Client.token(
          ctx.key,
          %{
            "grant_type" => "refresh_token",
            "client_id" => granted.client_id,
            "refresh_token" => tokens["refresh_token"]
          },
          granted.nonce
        )

      assert conn.status == 200
      rotated = Client.json(conn)
      assert rotated["refresh_token"] != tokens["refresh_token"]
      assert rotated["access_token"] != tokens["access_token"]
      assert rotated["sub"] == ctx.user.did
      assert rotated["scope"] == "atproto transition:generic"
    end

    test "revoking a refresh token kills the session, access token included", ctx do
      granted = Client.approve(ctx.user, ctx.key)
      tokens = tokens_for(ctx, granted)

      conn = Client.revoke(ctx.key, tokens["refresh_token"], granted.nonce)
      assert conn.status == 200

      conn =
        Client.token(
          ctx.key,
          %{
            "grant_type" => "refresh_token",
            "client_id" => granted.client_id,
            "refresh_token" => tokens["refresh_token"]
          },
          granted.nonce
        )

      assert Client.error(conn) == "invalid_grant"
      assert {:error, :invalid_token} = OAuth.verify_access_token(tokens["access_token"])
    end

    test "revoking an unknown token is not an error", ctx do
      pushed = Client.par(ctx.key)
      conn = Client.revoke(ctx.key, "ref-nobody-has-this", Client.nonce_from(pushed.conn))

      assert conn.status == 200
    end
  end

  describe "PKCE and the redirect" do
    test "a wrong code verifier is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)

      conn = code_exchange(ctx, granted, code_verifier: Client.pkce().verifier)

      assert Client.error(conn) == "invalid_grant"
    end

    test "a missing code verifier is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)

      conn =
        Client.exchange(
          ctx.key,
          %{
            "grant_type" => "authorization_code",
            "client_id" => granted.client_id,
            "code" => granted.code,
            "redirect_uri" => granted.redirect_uri
          },
          nonce: granted.nonce
        )

      assert Client.error(conn) == "invalid_request"
    end

    test "a wrong redirect_uri at the token endpoint is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)

      conn = code_exchange(ctx, granted, redirect_uri: "http://127.0.0.1:9999/other")

      assert Client.error(conn) == "invalid_grant"
    end

    test "a redirect_uri the client never registered is refused at PAR", ctx do
      params = Map.put(base_params(), "redirect_uri", "https://evil.example.com/steal")

      # First push earns the nonce; the second is refused on the redirect_uri.
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))
      conn = Client.form_par(ctx.key, params, nonce)

      assert conn.status == 400
      assert Client.error(conn) == "invalid_request"
    end

    test "PKCE with plain is refused, and so is a request with no challenge", ctx do
      for params <- [
            Map.put(base_params(), "code_challenge_method", "plain"),
            Map.delete(base_params(), "code_challenge"),
            Map.delete(base_params(), "code_challenge_method")
          ] do
        nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))
        assert Client.error(Client.form_par(ctx.key, params, nonce)) == "invalid_request"
      end
    end
  end

  describe "single use" do
    test "a code cannot be exchanged twice", ctx do
      granted = Client.approve(ctx.user, ctx.key)

      assert code_exchange(ctx, granted).status == 200
      assert Client.error(code_exchange(ctx, granted)) == "invalid_grant"
    end

    test "a replayed refresh token is refused and revokes the session", ctx do
      granted = Client.approve(ctx.user, ctx.key)
      tokens = tokens_for(ctx, granted)

      rotated =
        ctx.key
        |> Client.token(
          %{
            "grant_type" => "refresh_token",
            "client_id" => granted.client_id,
            "refresh_token" => tokens["refresh_token"]
          },
          granted.nonce
        )
        |> Client.json()

      # The token that was already spent, presented a second time.
      replay =
        Client.token(
          ctx.key,
          %{
            "grant_type" => "refresh_token",
            "client_id" => granted.client_id,
            "refresh_token" => tokens["refresh_token"]
          },
          granted.nonce
        )

      assert Client.error(replay) == "invalid_grant"

      # And the session it belonged to is gone, including the token the replay
      # would otherwise have renewed into.
      assert {:error, :invalid_token} = OAuth.verify_access_token(rotated["access_token"])

      dead =
        Client.token(
          ctx.key,
          %{
            "grant_type" => "refresh_token",
            "client_id" => granted.client_id,
            "refresh_token" => rotated["refresh_token"]
          },
          granted.nonce
        )

      assert Client.error(dead) == "invalid_grant"
    end

    test "an approved request_uri cannot be approved again", ctx do
      pushed = Client.par(ctx.key)

      first = Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle)
      assert first.status == 302

      second = Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle)
      assert second.status == 400
      assert Client.error(second) == "invalid_request"
    end

    test "a denied request redirects with access_denied and mints nothing", ctx do
      pushed = Client.par(ctx.key)

      conn =
        Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle, "deny")

      assert conn.status == 302
      location = conn |> get_resp_header("location") |> hd()
      query = URI.decode_query(URI.parse(location).query)
      assert query["error"] == "access_denied"
      assert query["state"] == pushed.params["state"]
    end
  end

  describe "login" do
    test "a wrong password grants nothing", ctx do
      pushed = Client.par(ctx.key)

      conn =
        Client.decide(
          pushed.request_uri,
          pushed.params["client_id"],
          ctx.user.handle,
          "approve",
          "not the password"
        )

      assert conn.status == 401
      assert Client.error(conn) == "access_denied"

      # The request survives a failed login, so the user can try again.
      retry = Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle)
      assert retry.status == 302
    end

    test "a login_hint for an account this server does not host is refused at PAR", ctx do
      params = Map.put(base_params(), "login_hint", "nobody.localhost")
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))

      assert Client.error(Client.form_par(ctx.key, params, nonce)) == "invalid_request"
    end

    test "a login_hint binds the flow to that account", ctx do
      other = create_account("bob")

      params = Map.put(base_params(), "login_hint", ctx.user.handle)
      pushed = Client.par(ctx.key, params: params)

      # Logging in as somebody else fails: the flow started with one account.
      conn = Client.decide(pushed.request_uri, pushed.params["client_id"], other.handle)
      assert conn.status == 400
      assert Client.error(conn) == "invalid_request"

      mine = Client.decide(pushed.request_uri, pushed.params["client_id"], ctx.user.handle)
      assert mine.status == 302
    end
  end

  describe "the authorize endpoint" do
    test "an unknown request_uri gets the login page refused", ctx do
      pushed = Client.par(ctx.key)
      unknown = pushed.request_uri <> "x"

      conn = Client.authorize_page(unknown, pushed.params["client_id"])
      assert conn.status == 400
      assert Client.error(conn) == "invalid_request"
    end

    test "a request_uri for another client is refused", ctx do
      pushed = Client.par(ctx.key)

      conn =
        Client.authorize_page(
          pushed.request_uri,
          "http://localhost?redirect_uri=http://127.0.0.1:1/cb"
        )

      assert conn.status == 400
      assert Client.error(conn) == "invalid_request"
    end

    test "the login page is not cacheable and posts only to this origin", ctx do
      pushed = Client.par(ctx.key)
      conn = Client.authorize_page(pushed.request_uri, pushed.params["client_id"])

      assert get_resp_header(conn, "cache-control") == ["no-store"]

      csp = get_resp_header(conn, "content-security-policy") |> hd()
      assert csp =~ "default-src 'none'"
      assert csp =~ "form-action 'self'"
    end
  end

  describe "scopes" do
    test "a scope this server does not grant is refused", ctx do
      params = Map.put(base_params(), "scope", "atproto transition:chat.bsky")
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))

      conn = Client.form_par(ctx.key, params, nonce)
      assert Client.error(conn) == "invalid_scope"
    end

    test "a request without the atproto scope is refused", ctx do
      params = Map.put(base_params(), "scope", "transition:generic")
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))

      assert Client.error(Client.form_par(ctx.key, params, nonce)) == "invalid_scope"
    end

    test "openid is refused rather than ignored", ctx do
      params = Map.put(base_params(), "scope", "atproto openid")
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))

      assert Client.error(Client.form_par(ctx.key, params, nonce)) == "invalid_scope"
    end

    test "a scope the client never declared is refused", ctx do
      # This client declares atproto and nothing else, so asking for
      # transition:generic is a client asking for something it does not have.
      client = Client.client_id(scope: "atproto")
      params = Map.put(base_params(), "client_id", client)

      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))
      assert Client.error(Client.form_par(ctx.key, params, nonce)) == "invalid_scope"
    end

    test "atproto on its own is accepted", ctx do
      client = Client.client_id(scope: "atproto")
      params = base_params() |> Map.put("scope", "atproto") |> Map.put("client_id", client)
      nonce = Client.nonce_from(Client.par_rejected(ctx.key, params))
      assert Client.form_par(ctx.key, params, nonce).status == 200
    end
  end

  describe "the token endpoint" do
    test "an unsupported grant type is refused", ctx do
      conn =
        Client.token(
          ctx.key,
          %{
            "grant_type" => "password",
            "client_id" => Client.client_id(),
            "username" => ctx.user.handle
          },
          Client.nonce_from(Client.par_rejected(ctx.key, base_params()))
        )

      assert Client.error(conn) == "unsupported_grant_type"
    end

    test "a code from another client is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)
      other = Client.client_id(redirect_uri: "http://127.0.0.1:8080/other")

      conn = code_exchange(ctx, granted, client_id: other)
      assert Client.error(conn) == "invalid_grant"
    end
  end

  defp code_exchange(ctx, granted, overrides \\ []) do
    %{
      "grant_type" => "authorization_code",
      "client_id" => Keyword.get(overrides, :client_id, granted.client_id),
      "code" => granted.code,
      "code_verifier" => Keyword.get(overrides, :code_verifier, granted.verifier),
      "redirect_uri" => Keyword.get(overrides, :redirect_uri, granted.redirect_uri)
    }
    |> then(fn params -> Client.exchange(ctx.key, params, nonce: granted.nonce) end)
  end

  defp tokens_for(ctx, granted) do
    code_exchange(ctx, granted) |> Client.json()
  end

  defp base_params do
    code = Client.pkce()

    %{
      "client_id" => Client.client_id(),
      "response_type" => "code",
      "redirect_uri" => Client.redirect_uri(),
      "scope" => "atproto transition:generic",
      "state" => Client.state(),
      "code_challenge" => code.challenge,
      "code_challenge_method" => "S256"
    }
  end
end
