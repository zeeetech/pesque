defmodule Pesque.ServiceAuth do
  @moduledoc """
  Short-lived tokens this server mints for another service to accept.

  A session token is signed with the server secret because the server is the
  only party that checks it. A service auth token is the opposite: the
  recipient verifies it against the account's public key from the account's
  DID document, which this server publishes and does not control. Signing it
  with the server secret would produce a token only this server could ever
  verify, so the key here is the account's, the same one that signs its commits.

  ES256K over the JWS compact form, so the token is a JWT that any ATProto
  implementation can verify with the published multibase key.
  """

  alias Pesque.Keys
  alias Pesque.Secp256k1

  @default_ttl_seconds 60
  @max_ttl_seconds 3_600

  # did:web or did:plc, a method-specific id, and an optional #serviceId
  # fragment. Bounded by maxLength 2048 in the lexicon, and a token claiming to
  # be for something longer than that is not a thing the lexicon describes.
  @aud_regex ~r/\Adid:(web|plc):[a-zA-Z0-9._%\-]+(:[a-zA-Z0-9._\-]+)*(#[a-zA-Z0-9._\-]+)?\z/
  @aud_max_length 2048

  @nsid_regex ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/

  @doc """
  Mints a service auth token for `did`, and answers the compact JWT.

  `opts` carries `:exp` (unix seconds) and `:lxm` (an NSID). Answers
  {:error, reason} for anything it will not sign.
  """
  @spec mint(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def mint(did, aud, opts \\ []) do
    with :ok <- check_aud(aud),
         :ok <- check_lxm(opts[:lxm]),
         {:ok, exp} <- check_exp(opts[:exp]),
         {:ok, priv} <- signing_key(did) do
      {:ok, sign(priv, did, aud, exp, opts[:lxm])}
    end
  end

  # aud is what the token asserts about the recipient, so a value that is not a
  # DID reference would mint a token no recipient could match against its own
  # identity, and one that is too long is outside what the lexicon allows.
  defp check_aud(aud) when is_binary(aud) do
    if byte_size(aud) <= @aud_max_length and Regex.match?(@aud_regex, aud),
      do: :ok,
      else: {:error, :invalid_audience}
  end

  defp check_aud(_aud), do: {:error, :invalid_audience}

  # lxm narrows the token to one method, so it has to be an NSID: a string that
  # is not one could never equal a method name and would only make the token
  # look scoped when it is not.
  defp check_lxm(nil), do: :ok

  defp check_lxm(lxm) when is_binary(lxm) do
    if Regex.match?(@nsid_regex, lxm), do: :ok, else: {:error, :invalid_lxm}
  end

  defp check_lxm(_lxm), do: {:error, :invalid_lxm}

  # An expiration is only ever refused, never widened: a client asking for a
  # token that already expired gets nothing, and one asking for a year gets a
  # minute. The cap is what keeps this endpoint from being a way to mint
  # long-lived credentials.
  defp check_exp(nil), do: {:ok, System.system_time(:second) + @default_ttl_seconds}

  defp check_exp(exp) when is_integer(exp) do
    now = System.system_time(:second)

    cond do
      exp <= now -> {:error, :bad_expiration}
      exp - now > @max_ttl_seconds -> {:error, :bad_expiration}
      true -> {:ok, exp}
    end
  end

  defp check_exp(_exp), do: {:error, :bad_expiration}

  # The key an account's commits are signed with, loaded through the same path
  # RepoServer loads it. A key this server cannot read means the account's
  # repo cannot sign either, and it is a server fault rather than the caller's.
  defp signing_key(did) do
    case Keys.ensure(did) do
      {:ok, %{priv: priv}} -> {:ok, priv}
      {:error, _reason} -> {:error, :key_unavailable}
    end
  end

  defp sign(priv, did, aud, exp, lxm) do
    claims =
      %{"iss" => did, "aud" => aud, "iat" => System.system_time(:second), "exp" => exp}
      |> put_lxm(lxm)

    header = %{"typ" => "JWT", "alg" => "ES256K"}

    input = encode(JSON.encode!(header)) <> "." <> encode(JSON.encode!(claims))

    input <> "." <> encode(Secp256k1.sign(priv, input))
  end

  # An absent lxm leaves the claim out rather than setting it to null: the
  # reference implementation does the same, and a null claim is not the same
  # claim as no claim to whoever reads the token.
  defp put_lxm(claims, nil), do: claims
  defp put_lxm(claims, lxm), do: Map.put(claims, "lxm", lxm)

  defp encode(bin), do: Base.url_encode64(bin, padding: false)
end
