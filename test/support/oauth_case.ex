defmodule PesqueWeb.OAuthCase do
  @moduledoc """
  A client, driven over real requests, for the OAuth tests.

  Everything the atproto profile makes a client do is done here rather than in
  each test: it mints a P-256 DPoP key, signs a proof per request, pushes the
  authorization request, answers the nonce the server hands back, logs in, and
  exchanges the code. A test that skipped the proof or the nonce round trip
  would be testing a server nobody uses.

  The client is the localhost one the spec makes an exception for, so no test
  reaches the network to fetch a metadata document.

  `par/2` answers the request_uri and the verifier matching its challenge
  together, because the two travel as a pair and a test holding only one of them
  would not be testing a flow a client can complete.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  alias Pesque.OAuth.DPoP
  alias Pesque.OAuth.Jwt
  alias PesqueWeb.Endpoint

  @password "hunter2hunter2"
  @redirect_uri "http://127.0.0.1:8080/callback"

  @doc "A fresh DPoP keypair for one client session."
  def dpop_key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-32, y::binary-32>> = pub

    %{
      priv: priv,
      jwk: %{
        "kty" => "EC",
        "crv" => "P-256",
        "x" => Base.url_encode64(x, padding: false),
        "y" => Base.url_encode64(y, padding: false)
      }
    }
  end

  @doc "A PKCE verifier and its S256 challenge."
  def pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %{
      verifier: verifier,
      challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    }
  end

  @doc "A random `state`."
  def state, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @doc """
  A DPoP proof for one request.

  `nonce` is the value from the last response's `DPoP-Nonce` header, `ath` the
  access token when the request carries one, and `overrides` replaces claims so a
  test can build a proof wrong in exactly one way.
  """
  def proof(key, method, path, opts \\ []) do
    claims = %{
      "htm" => method,
      "htu" => Pesque.base_url() <> path,
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "iat" => System.system_time(:second)
    }

    claims = maybe_put(claims, "nonce", opts[:nonce])
    claims = maybe_put(claims, "ath", access_hash(opts[:ath]))
    claims = Map.merge(claims, Map.new(Keyword.get(opts, :overrides, []) || []))

    header = %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => key.jwk}
    input = encode(JSON.encode!(header)) <> "." <> encode(JSON.encode!(claims))

    input <> "." <> encode(Jwt.sign_raw(input, key.priv))
  end

  defp maybe_put(claims, _key, nil), do: claims
  defp maybe_put(claims, key, value), do: Map.put(claims, key, value)

  defp access_hash(nil), do: nil
  defp access_hash(token), do: DPoP.access_token_hash(token)

  defp encode(bin), do: Base.url_encode64(bin, padding: false)

  @doc """
  The client_id of the localhost development client.

  The spec has this client declare its redirect URIs and its scopes by query
  parameter, and its scopes default to `atproto` alone. This one declares both,
  because the tests ask for `transition:generic` and a request for a scope the
  client never declared is refused by design.
  """
  def client_id(opts \\ []) do
    query =
      URI.encode_query(%{
        "redirect_uri" => Keyword.get(opts, :redirect_uri, @redirect_uri),
        "scope" => Keyword.get(opts, :scope, "atproto transition:generic")
      })

    "http://localhost?" <> query
  end

  @doc "The redirect_uri the helper's client registers by default."
  def redirect_uri, do: @redirect_uri

  @doc """
  Pushes an authorization request.

  Answers `%{request_uri:, verifier:, params:, conn:}` where `conn` is the
  accepted push. The nonce round trip is inside here because it is part of PAR:
  the first push carries no nonce, the server answers `use_dpop_nonce` with one,
  and the second carries it. A test that only pushed once would not exercise the
  path a real client takes.
  """
  def par(key, overrides \\ []) do
    {params, verifier} = par_params(overrides)
    _ = par_rejected(key, params)
    conn = par_accepted(key, params)

    case JSON.decode(conn.resp_body) do
      {:ok, %{"request_uri" => request_uri}} ->
        %{
          request_uri: request_uri,
          verifier: verifier,
          params: params,
          conn: conn,
          nonce: nonce_from(conn)
        }

      {:ok, other} ->
        raise "PAR was not accepted: #{inspect(other)}"

      _other ->
        raise "PAR did not answer JSON: #{inspect(conn.resp_body)}"
    end
  end

  @doc "A push that carries no server nonce, which the server answers `use_dpop_nonce`."
  def par_rejected(key, params) do
    form(key, "/oauth/par", params, nil)
  end

  @doc "A push carrying `nonce`."
  def par_accepted(key, params) do
    nonce = nonce_from(par_rejected(key, params))
    form(key, "/oauth/par", params, nonce)
  end

  @doc "A push carrying an explicit `nonce`, so a test can control the retry."
  def form_par(key, params, nonce) do
    form(key, "/oauth/par", params, nonce)
  end

  @doc "The RFC 7638 thumbprint of a DPoP key, which is what a session binds to."
  def dpop_key_jkt(key), do: Jwt.thumbprint(key.jwk)

  defp par_params(overrides) do
    code = pkce()

    params = %{
      "client_id" => Keyword.get(overrides, :client_id, client_id()),
      "response_type" => "code",
      "redirect_uri" => Keyword.get(overrides, :redirect_uri, @redirect_uri),
      "scope" => Keyword.get(overrides, :scope, "atproto transition:generic"),
      "state" => Keyword.get(overrides, :state, state()),
      "code_challenge" => Keyword.get(overrides, :code_challenge, code.challenge),
      "code_challenge_method" => Keyword.get(overrides, :code_challenge_method, "S256")
    }

    {Map.merge(params, Map.new(Keyword.get(overrides, :params, []))), code.verifier}
  end

  @doc "The GET on the authorize page, which is the login form."
  def authorize_page(request_uri, client_id) do
    query = URI.encode_query(%{"client_id" => client_id, "request_uri" => request_uri})

    conn()
    |> put_req_header("x-forwarded-for", address())
    |> dispatch(Endpoint, :get, "/oauth/authorize?" <> query)
  end

  @doc "Posts the login form with a decision, answering the conn."
  def decide(request_uri, client_id, identifier, decision \\ "approve", password \\ @password) do
    post_form("/oauth/authorize", %{
      "client_id" => client_id,
      "request_uri" => request_uri,
      "identifier" => identifier,
      "password" => password,
      "decision" => decision
    })
  end

  @doc """
  PAR, then the login form, then approval.

  Answers `%{request_uri:, code:, verifier:, client_id:, redirect_uri:, conn:}`,
  where `conn` is the redirect carrying the code.
  """
  def approve(user, key, overrides \\ []) do
    pushed = par(key, overrides)
    client_id = pushed.params["client_id"]
    conn = decide(pushed.request_uri, client_id, user.handle)

    if conn.status != 302 do
      raise "authorize answered #{conn.status}: #{inspect(conn.resp_body)}"
    end

    location = conn |> get_resp_header("location") |> hd()
    returned = URI.decode_query(URI.parse(location).query)

    Map.merge(pushed, %{
      code: returned["code"],
      client_id: client_id,
      redirect_uri: pushed.params["redirect_uri"],
      location: location,
      returned: returned,
      conn: conn,
      nonce: nonce_from(pushed.conn)
    })
  end

  @doc "Any POST to the token endpoint with an arbitrary body, answering the conn."
  def token(key, params, nonce \\ nil, claims \\ nil) do
    form(key, "/oauth/token", params, nonce, claims)
  end

  def exchange(key, params, arg \\ [])

  @doc "Exchanges an approved code for tokens, answering the conn."
  def exchange(key, params, opts) when is_list(opts) do
    token(key, params, Keyword.get(opts, :nonce), Keyword.get(opts, :claims))
  end

  def exchange(key, params, nonce) when is_binary(nonce), do: token(key, params, nonce)

  @doc """
  Runs PAR, approval and exchange, answering the token conn.

  The nonce is the one the accepted PAR response handed out and is reused for
  the token request, which is what a client does with the last nonce it was
  given. A token request without it answers `use_dpop_nonce`.
  """
  def tokens_for(user, key, overrides \\ []) do
    granted = approve(user, key, overrides)

    conn =
      exchange(
        key,
        %{
          "grant_type" => "authorization_code",
          "client_id" => granted.client_id,
          "code" => granted.code,
          "code_verifier" => granted.verifier,
          "redirect_uri" => granted.redirect_uri
        },
        nonce: granted.nonce
      )

    Map.put(granted, :token_conn, conn)
  end

  @doc "Revokes a token, answering the conn."
  def revoke(key, token, nonce \\ nil) do
    form(key, "/oauth/revoke", %{"token" => token}, nonce)
  end

  @doc "The JSON body of a response, decoded."
  def json(conn) do
    case JSON.decode(conn.resp_body) do
      {:ok, body} -> body
      _other -> raise "expected JSON, got #{inspect(conn.resp_body)}"
    end
  end

  @doc "The `error` code a failure response carries."
  def error(conn) do
    case json(conn) do
      %{"error" => error} -> error
      other -> raise "expected an OAuth error, got #{inspect(other)}"
    end
  end

  @doc "The `DPoP-Nonce` a response handed out, or nil."
  def nonce_from(conn) do
    conn |> get_resp_header("dpop-nonce") |> List.first()
  end

  # The rate limiter counts by address and its ETS table outlives a test's
  # transaction, so every request here claims its own address through
  # x-forwarded-for. Without that, a suite making a hundred OAuth requests
  # exhausts one window's budget partway through and the failures look like
  # protocol bugs rather than test-isolation ones.
  defp form(key, path, params, nonce, claims \\ nil) do
    conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-forwarded-for", address())
    |> put_req_header("dpop", proof(key, "POST", path, nonce: nonce, overrides: claims))
    |> dispatch(Endpoint, :post, path, URI.encode_query(stringify(params)))
  end

  defp post_form(path, params) do
    conn()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("x-forwarded-for", address())
    |> dispatch(Endpoint, :post, path, URI.encode_query(stringify(params)))
  end

  defp conn, do: build_conn()

  defp address do
    <<a, b, _::binary>> = :crypto.strong_rand_bytes(4)
    "203.0.#{a}.#{b}"
  end

  defp stringify(params) do
    Map.new(params, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
