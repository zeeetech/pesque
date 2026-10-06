defmodule Pesque.Token do
  @moduledoc """
  Hand-rolled HS256 JWTs. The format is simple enough that pulling in a
  library buys nothing: base64url(header) <> "." <> base64url(claims),
  HMAC-SHA256 over the pair.
  """

  @access_ttl_seconds 2 * 60 * 60
  @refresh_ttl_seconds 90 * 24 * 60 * 60

  @doc "Lifetime of an access token, in seconds."
  def access_ttl_seconds, do: @access_ttl_seconds

  @doc "Lifetime of a refresh token, in seconds."
  def refresh_ttl_seconds, do: @refresh_ttl_seconds

  @doc "Signs `claims` into a compact JWT. `secret` is the HMAC key."
  def sign(claims, secret) do
    header = JSON.encode!(%{"alg" => "HS256", "typ" => "JWT"})
    payload = JSON.encode!(claims)
    input = b64(header) <> "." <> b64(payload)
    input <> "." <> b64(:crypto.mac(:hmac, :sha256, secret, input))
  end

  @doc "Verifies signature, expiry, and scope. Returns {:ok, claims} | {:error, :invalid_token}."
  def verify(token, secret, expected_scope) do
    with {:ok, header, payload, sig64} <- split(token),
         {:ok, sig} <- Base.url_decode64(sig64, padding: false),
         :ok <- verify_mac(header <> "." <> payload, sig, secret),
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- JSON.decode(decoded),
         :ok <- check_claims(claims, expected_scope) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp split(token) do
    case String.split(token, ".", parts: 3) do
      [header, payload, sig64] -> {:ok, header, payload, sig64}
      _other -> :error
    end
  end

  defp verify_mac(input, sig, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, input)

    if byte_size(expected) == byte_size(sig) and Plug.Crypto.secure_compare(expected, sig) do
      :ok
    else
      :error
    end
  end

  defp check_claims(claims, expected_scope) do
    now = System.system_time(:second)

    cond do
      claims["scope"] != expected_scope -> :error
      not is_integer(claims["exp"]) -> :error
      claims["exp"] <= now -> :error
      not is_binary(claims["sub"]) -> :error
      true -> :ok
    end
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
