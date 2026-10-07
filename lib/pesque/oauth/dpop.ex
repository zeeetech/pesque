defmodule Pesque.OAuth.DPoP do
  @moduledoc """
  Checking a DPoP proof (RFC 9449) and the `jkt` that binds a session to a key.

  A proof is a JWT whose header carries the public key it was signed with, so
  verifying the signature and learning which key that was are the same act.
  What comes out of here is the thumbprint, and every token minted for the
  session carries it, so a token lifted off one device cannot be replayed from
  another.

  Checked, in order: the algorithm is ES256 and the type is dpop+jwt; the
  signature verifies against the embedded key; `htm` is this request's method;
  `htu` is this request's URL without query or fragment; `jti` is present;
  `iat` is present and recent; `ath`, when the request carries an access token,
  is the hash of that token; and the nonce is one this server issued.

  Every failure answers a reason rather than raising, because every one of
  these is reachable by a stranger sending a crafted string.
  """

  alias Pesque.OAuth.Jwt
  alias Pesque.OAuth.Nonce

  # RFC 9449 has the server reject a proof older than a small window; the
  # reference implementation allows 10 seconds of skew plus its nonce age.
  @max_age_seconds 300

  @doc """
  Checks the proof for one request.

  `access_token` is the bearer presented with the request, or nil. Answer is
  {:ok, %{jkt:, jti:}} or {:error, reason}, where :use_dpop_nonce is the one
  reason a client can fix by retrying with the nonce from the response header.
  """
  def check(proof, method, url, access_token \\ nil)

  def check(proof, method, url, access_token) when is_binary(proof) do
    with {:ok, header, claims, input, signature} <- Jwt.decode(proof),
         :ok <- check_header(header),
         :ok <- check_signature(input, signature, header["jwk"]),
         :ok <- check_method(claims, method),
         :ok <- check_url(claims, url),
         :ok <- check_jti(claims),
         :ok <- check_age(claims),
         :ok <- check_ath(claims, access_token),
         :ok <- Nonce.check(claims["nonce"]) do
      {:ok, %{jkt: Jwt.thumbprint(header["jwk"]), jti: claims["jti"]}}
    end
  end

  def check(_proof, _method, _url, _access_token), do: {:error, :missing_dpop_proof}

  @doc """
  The `ath` value for an access token, as the proof must carry it.

  Public so the resource-server side hashes the same way the token endpoint
  checks: base64url of the SHA-256 of the token, unpadded, which is what
  RFC 9449 section 4.2 specifies.
  """
  def access_token_hash(access_token) when is_binary(access_token) do
    Base.url_encode64(:crypto.hash(:sha256, access_token), padding: false)
  end

  # Only ES256. `none` would make the embedded key decorative, and any other
  # algorithm is a key type the server has no reason to trust here.
  defp check_header(%{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => jwk})
       when is_map(jwk) do
    case Jwt.thumbprint(jwk) do
      {:error, reason} -> {:error, reason}
      _jkt -> :ok
    end
  end

  defp check_header(_header), do: {:error, :invalid_dpop_proof}

  defp check_signature(input, signature, jwk) do
    with {:ok, public_key} <- Jwt.public_key(jwk),
         # 0x04 is the uncompressed point marker; public_key/1 refuses anything
         # that is not a 32-byte-half P-256 point, which must not reach :crypto.
         true <- Jwt.verify_es256(input, signature, public_key) do
      :ok
    else
      _ -> {:error, :invalid_dpop_proof}
    end
  end

  # rfc9110 section 9.1: the method is case-sensitive.
  defp check_method(%{"htm" => method}, method), do: :ok
  defp check_method(_claims, _method), do: {:error, :htm_mismatch}

  defp check_url(%{"htu" => htu}, url) when is_binary(htu) do
    if normalize_url(htu) == normalize_url(url) do
      :ok
    else
      {:error, :htu_mismatch}
    end
  end

  defp check_url(_claims, _url), do: {:error, :htu_mismatch}

  # The query and the fragment are not part of htu (RFC 9449 section 4.3), and
  # the token endpoint's query string in particular varies with nothing that
  # should change the binding.
  defp normalize_url(url) do
    case URI.new(url) do
      {:ok, uri} -> %{uri | query: nil, fragment: nil} |> URI.to_string()
      _ -> url
    end
  end

  defp check_jti(%{"jti" => jti}) when is_binary(jti) and byte_size(jti) > 0, do: :ok
  defp check_jti(_claims), do: {:error, :missing_jti}

  defp check_age(%{"iat" => iat}) when is_integer(iat) do
    now = System.system_time(:second)

    if iat > now + @max_age_seconds or iat < now - @max_age_seconds do
      {:error, :expired_dpop_proof}
    else
      :ok
    end
  end

  defp check_age(_claims), do: {:error, :missing_iat}

  # With an access token in hand the proof has to be over that token, which is
  # what stops a proof captured on one endpoint being carried to another. With
  # no token, a proof that carries ath anyway is a client that has confused
  # which request it is signing.
  defp check_ath(%{"ath" => ath}, access_token) when is_binary(access_token) do
    if ath == access_token_hash(access_token), do: :ok, else: {:error, :ath_mismatch}
  end

  defp check_ath(claims, nil) do
    if Map.has_key?(claims, "ath"), do: {:error, :ath_not_allowed}, else: :ok
  end

  defp check_ath(_claims, _access_token), do: {:error, :ath_mismatch}
end
