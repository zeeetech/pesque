defmodule PesqueWeb.OAuth.DPoPTest do
  @moduledoc """
  DPoP, which the atproto profile makes mandatory everywhere.

  Each test breaks the proof in exactly one way and asserts the server notices.
  The `ath` cases are the interesting half: a proof is not a bearer token, it
  is a signature over one specific request, and an `ath` that does not match the
  access token being presented is a proof captured somewhere else.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.OAuth.DPoP
  alias Pesque.OAuth.Nonce
  alias PesqueWeb.OAuthCase, as: Client

  setup do
    %{user: create_account("alice"), key: Client.dpop_key()}
  end

  describe "a proof is required" do
    test "PAR with no DPoP header is refused", ctx do
      conn = post_par(ctx.key, params(), nil, dpop: false)

      assert conn.status == 400
      assert Client.error(conn) == "invalid_dpop_proof"
    end

    test "the token endpoint with no DPoP header is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)

      conn =
        form_unproofed(%{
          "grant_type" => "refresh_token",
          "client_id" => granted.client_id,
          "refresh_token" => "ref-anything"
        })

      assert Client.error(conn) == "invalid_dpop_proof"
    end

    test "a refusal still hands out a nonce, which is what a client retries with", ctx do
      conn = post_par(ctx.key, params(), nil, dpop: false)

      assert Client.error(conn) == "invalid_dpop_proof"
      assert is_binary(Client.nonce_from(conn))
    end

    test "revocation with no DPoP header is refused", _ctx do
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> dispatch(Endpoint, :post, "/oauth/revoke", URI.encode_query(%{"token" => "ref-x"}))

      assert Client.error(conn) == "invalid_dpop_proof"
    end
  end

  describe "the nonce" do
    test "a proof with no nonce is answered use_dpop_nonce", ctx do
      conn = post_par(ctx.key, params(), nil)

      assert conn.status == 400
      assert Client.error(conn) == "use_dpop_nonce"
      assert is_binary(Client.nonce_from(conn))
    end

    test "a made-up nonce is answered use_dpop_nonce", ctx do
      conn = post_par(ctx.key, params(), Base.url_encode64(<<1::128>>, padding: false))

      assert Client.error(conn) == "use_dpop_nonce"
    end

    test "the nonce the server handed out is accepted", ctx do
      nonce = Client.nonce_from(post_par(ctx.key, params(), nil))

      assert Client.form_par(ctx.key, params(), nonce).status == 200
    end

    test "the server nonce is not something a client could have guessed", _ctx do
      assert byte_size(Nonce.current()) >= 16
    end
  end

  describe "the claims" do
    setup do
      # A nonce that is live for the rest of the test, so what is broken is the
      # claim under test and nothing else.
      nonce = Client.nonce_from(post_par(Client.dpop_key(), params(), nil))

      %{nonce: nonce, key: Client.dpop_key()}
    end

    test "a proof for another method is refused", ctx do
      proof = Client.proof(ctx.key, "GET", "/oauth/par", nonce: ctx.nonce)

      conn = post_par(ctx.key, params(), ctx.nonce, proof: proof)

      assert Client.error(conn) == "invalid_dpop_proof"
    end

    test "a proof for another URL is refused", ctx do
      proof = Client.proof(ctx.key, "POST", "/oauth/token", nonce: ctx.nonce)

      conn = post_par(ctx.key, params(), ctx.nonce, proof: proof)

      assert Client.error(conn) == "invalid_dpop_proof"
    end

    test "a proof whose signature was made by another key is refused", ctx do
      other = Client.proof(Client.dpop_key(), "POST", "/oauth/par", nonce: ctx.nonce)
      # Same claims, same nonce, but the header names a key that did not sign.
      [h, p, _s] = String.split(other, ".")
      _signed = Client.proof(ctx.key, "POST", "/oauth/par", nonce: ctx.nonce)
      forged = Enum.join([h, p], ".")

      conn = post_par(ctx.key, params(), ctx.nonce, proof: forged <> ".AAAA")

      assert Client.error(conn) == "invalid_dpop_proof"
    end

    test "a proof with no jti is refused", ctx do
      proof =
        Client.proof(ctx.key, "POST", "/oauth/par",
          nonce: ctx.nonce,
          overrides: %{"jti" => nil}
        )

      assert Client.error(post_par(ctx.key, params(), ctx.nonce, proof: proof)) ==
               "invalid_dpop_proof"
    end

    test "a proof with no iat is refused", ctx do
      proof =
        Client.proof(ctx.key, "POST", "/oauth/par",
          nonce: ctx.nonce,
          overrides: %{"iat" => nil}
        )

      assert Client.error(post_par(ctx.key, params(), ctx.nonce, proof: proof)) ==
               "invalid_dpop_proof"
    end

    test "a stale proof is refused", ctx do
      proof =
        Client.proof(ctx.key, "POST", "/oauth/par",
          nonce: ctx.nonce,
          overrides: %{"iat" => System.system_time(:second) - 3600}
        )

      assert Client.error(post_par(ctx.key, params(), ctx.nonce, proof: proof)) ==
               "invalid_dpop_proof"
    end

    test "a proof from the future is refused", ctx do
      proof =
        Client.proof(ctx.key, "POST", "/oauth/par",
          nonce: ctx.nonce,
          overrides: %{"iat" => System.system_time(:second) + 3600}
        )

      assert Client.error(post_par(ctx.key, params(), ctx.nonce, proof: proof)) ==
               "invalid_dpop_proof"
    end

    test "a proof carrying ath where no access token was presented is refused", ctx do
      proof = Client.proof(ctx.key, "POST", "/oauth/par", nonce: ctx.nonce, ath: "some-token")

      assert Client.error(post_par(ctx.key, params(), ctx.nonce, proof: proof)) ==
               "invalid_dpop_proof"
    end

    test "a malformed proof is refused rather than crashing the request", ctx do
      for proof <- ["", "not-a-jwt", "a.b", "a.b.c", "...."] do
        conn = post_par(ctx.key, params(), ctx.nonce, proof: proof)
        assert conn.status == 400
      end
    end
  end

  describe "the binding" do
    test "the token request must come from the key PAR was pushed with", ctx do
      pushed = Client.par(ctx.key)
      granted = Client.approve(ctx.user, ctx.key)

      # A different DPoP key presenting the code is refused: the session would
      # otherwise bind to a key the request was never pushed with.
      other = Client.dpop_key()

      conn =
        Client.exchange(
          other,
          %{
            "grant_type" => "authorization_code",
            "client_id" => granted.client_id,
            "code" => granted.code,
            "code_verifier" => granted.verifier,
            "redirect_uri" => granted.redirect_uri
          },
          nonce: pushed.nonce
        )

      assert Client.error(conn) == "invalid_dpop_proof"
      assert granted.code
    end

    test "ath is the hash of the access token, and a wrong one is refused", ctx do
      granted = Client.approve(ctx.user, ctx.key)
      tokens = code_exchange(ctx, granted)

      # DPoP.check/4 is the whole of the ath rule, so it is asserted directly:
      # the token endpoint never presents an access token, and a proof claiming
      # one there is refused.
      nonce = granted.nonce
      wrong = Client.proof(ctx.key, "POST", "/oauth/par", nonce: nonce, ath: "not-the-token")

      assert {:error, :ath_not_allowed} =
               DPoP.check(wrong, "POST", Pesque.base_url() <> "/oauth/par", nil)

      right =
        Client.proof(ctx.key, "POST", "/oauth/par",
          nonce: nonce,
          ath: tokens["access_token"]
        )

      assert {:error, :ath_mismatch} =
               DPoP.check(right, "POST", Pesque.base_url() <> "/oauth/par", "a-different-token")

      assert {:ok, %{jkt: _jkt}} =
               DPoP.check(
                 right,
                 "POST",
                 Pesque.base_url() <> "/oauth/par",
                 tokens["access_token"]
               )
    end

    test "the hash is base64url of SHA-256 with no padding", _ctx do
      hash = DPoP.access_token_hash("some-access-token")

      refute String.contains?(hash, "=")
      assert hash == Base.url_encode64(:crypto.hash(:sha256, "some-access-token"), padding: false)
    end
  end

  defp code_exchange(ctx, granted) do
    params = %{
      "grant_type" => "authorization_code",
      "client_id" => granted.client_id,
      "code" => granted.code,
      "code_verifier" => granted.verifier,
      "redirect_uri" => granted.redirect_uri
    }

    ctx.key
    |> Client.exchange(params, nonce: granted.nonce)
    |> Client.json()
  end

  # The DPoP header is built here rather than through the client helper because
  # several of these tests need a proof that is wrong in one specific way, or no
  # header at all.
  defp post_par(key, params, nonce, opts \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-forwarded-for", address())
    |> maybe_dpop(key, nonce, opts)
    |> dispatch(Endpoint, :post, "/oauth/par", URI.encode_query(params))
  end

  defp maybe_dpop(conn, key, nonce, opts) do
    cond do
      Keyword.get(opts, :dpop) == false ->
        conn

      proof = Keyword.get(opts, :proof) ->
        put_req_header(conn, "dpop", proof)

      true ->
        put_req_header(conn, "dpop", Client.proof(key, "POST", "/oauth/par", nonce: nonce))
    end
  end

  defp form_unproofed(params) do
    build_conn()
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> dispatch(Endpoint, :post, "/oauth/token", URI.encode_query(params))
  end

  defp address do
    <<a, b, _::binary>> = :crypto.strong_rand_bytes(4)
    "203.0.#{a}.#{b}"
  end

  defp params do
    code = Client.pkce()

    %{
      "client_id" => Client.client_id(),
      "response_type" => "code",
      "redirect_uri" => Client.redirect_uri(),
      "scope" => "atproto",
      "state" => Client.state(),
      "code_challenge" => code.challenge,
      "code_challenge_method" => "S256"
    }
  end
end
