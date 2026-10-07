defmodule Pesque.OAuth.ClientAssertion do
  @moduledoc """
  Verifying a confidential client's `private_key_jwt` assertion.

  A confidential client holds a signing key, publishes its public half in its
  own metadata, and proves who it is on each request with a JWT signed by it:
  RFC 7523's `urn:ietf:params:oauth:client-assertion-type:jwt-bearer`. There is
  no client_secret anywhere in the atproto profile, so this is the whole of
  client authentication for a client that has a key.

  `iss` and `sub` must both be the client_id, `aud` must be this server, and
  `jti` must be present. The key is named by `kid` rather than searched for,
  which is what lets a client rotate keys by publishing both and using the new
  one.

  What is not here: the spec asks an authorization server to remember the `jti`
  values it has seen so an assertion cannot be replayed inside its own validity
  window. That is not implemented, so an assertion captured off the wire is
  good until it expires, which the iat window bounds to a minute. The session
  binding the spec also asks for, the client authentication key staying the same
  for the life of a session, is done: see Pesque.OAuth.
  """

  alias Pesque.OAuth.Client
  alias Pesque.OAuth.Jwt

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @max_age_seconds 60

  @doc """
  Verifies the assertion for `client_id` against the client's own published keys.

  Answers {:ok, %{jkt:, jti:, kid:}} or {:error, reason}.
  """
  def verify(client_id, metadata, assertion_type, assertion) do
    with :ok <- check_type(assertion_type),
         true <- is_binary(assertion),
         {:ok, keys} <- Client.jwks(metadata),
         {:ok, header, claims, input, signature} <- Jwt.decode(assertion),
         {:ok, key} <- select_key(keys, header["kid"]),
         :ok <- verify_signature(input, signature, key),
         :ok <- check_claims(claims, client_id, metadata) do
      {:ok, %{jkt: Jwt.thumbprint(key), jti: claims["jti"], kid: header["kid"]}}
    else
      _ -> {:error, :invalid_client_assertion}
    end
  end

  @doc "Whether a request carries a client assertion of any kind."
  def requested?(params) do
    is_binary(params["client_assertion"]) or is_binary(params["client_assertion_type"])
  end

  defp check_type(@assertion_type), do: :ok
  defp check_type(_other), do: {:error, :unsupported_assertion_type}

  # A key named by kid, or the sole key when the client published one and sent
  # no kid. Searching a set for whichever key happens to verify would let a
  # client that controls any one key of a set authenticate as one holding a
  # different one.
  defp select_key(keys, nil) when length(keys) == 1, do: single(keys)
  defp select_key(keys, kid) when is_binary(kid), do: find(keys, kid)
  defp select_key(_keys, _kid), do: {:error, :invalid_client_assertion}

  defp single([key]), do: {:ok, key}
  defp single(_keys), do: {:error, :invalid_client_assertion}

  defp find(keys, kid) do
    case Enum.find(keys, &(is_map(&1) and Map.get(&1, "kid") == kid)) do
      nil -> {:error, :unknown_client_key}
      key -> {:ok, key}
    end
  end

  defp verify_signature(input, signature, key) do
    with {:ok, public_key} <- Jwt.public_key(key),
         true <- Jwt.verify_es256(input, signature, public_key) do
      :ok
    else
      _ -> {:error, :invalid_client_assertion}
    end
  end

  defp check_claims(claims, client_id, metadata) do
    now = System.system_time(:second)
    iat = claims["iat"]

    if claims["iss"] == client_id and claims["sub"] == client_id and
         audience?(claims["aud"], Pesque.base_url()) and
         is_binary(claims["jti"]) and claims["jti"] != "" and
         is_integer(iat) and abs(now - iat) <= @max_age_seconds and
         not expired?(claims["exp"], now) and signing_alg(metadata) in [nil, "ES256"] do
      :ok
    else
      {:error, :invalid_client_assertion}
    end
  end

  defp expired?(exp, _now) when not is_integer(exp), do: false
  defp expired?(exp, now), do: exp <= now

  defp audience?(aud, issuer) when is_binary(aud), do: aud == issuer
  defp audience?(aud, issuer) when is_list(aud), do: issuer in aud
  defp audience?(_aud, _issuer), do: false

  defp signing_alg(%{"token_endpoint_auth_signing_alg" => alg}), do: alg
  defp signing_alg(_metadata), do: nil
end
