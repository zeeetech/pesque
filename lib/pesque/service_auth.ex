defmodule Pesque.ServiceAuth do
  @moduledoc """
  Short-lived tokens this server mints for another service to accept, and the
  other side of that: checking a token this server is the audience of.

  A session token is signed with the server secret because the server is the
  only party that checks it. A service auth token is the opposite: the
  recipient verifies it against the account's public key from the account's
  DID document, which this server publishes and does not control. Signing it
  with the server secret would produce a token only this server could ever
  verify, so the key here is the account's, the same one that signs its commits.

  ES256K over the JWS compact form, so the token is a JWT that any ATProto
  implementation can verify with the published multibase key.
  """

  alias Pesque.Base58
  alias Pesque.DidResolver
  alias Pesque.Keys
  alias Pesque.OAuth.Jwt
  alias Pesque.Secp256k1

  @default_ttl_seconds 60
  @max_ttl_seconds 3_600

  # A small allowance for clock drift between the two servers. `exp` is not
  # widened by it: an expired token is expired.
  @clock_skew_seconds 60

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

  @doc """
  Verifies a service auth token this server is the audience of.

  Answers `{:ok, did}`, the account the token was issued on behalf of, or
  `{:error, reason}`. The signature is checked against that account's published
  `#atproto` key, resolved from its DID document, so a token whose signature
  cannot be checked is refused rather than accepted.

  `audience` is this server's own DID reference and `lxm` the method being
  called; both must match the token's claims. `lxm` is required: the spec makes
  it mandatory for every authenticated XRPC request, and this is only ever the
  XRPC boundary, so a token without one is not scoped to the method and is not
  treated as a wildcard.

  Every failure is a tagged error and the token is never logged.
  """
  @spec verify(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def verify(token, audience, lxm)
      when is_binary(token) and is_binary(audience) and is_binary(lxm) do
    with {:ok, header, claims, input, signature} <- Jwt.decode(token),
         :ok <- check_header(header),
         :ok <- check_claims(claims, audience, lxm),
         {:ok, did} <- check_iss(claims),
         {:ok, document} <- DidResolver.resolve(did),
         {:ok, key} <- atproto_key(document),
         :ok <- check_signature(input, signature, key) do
      {:ok, did}
    end
  end

  def verify(_token, _audience, _lxm), do: {:error, :malformed_jwt}

  # The header is validated before any resolution work, so a token that does
  # not claim ES256K cannot make this server fetch a DID. Only ES256K selects
  # the algorithm: `none`, HMAC, RSA, and the OAuth ES256 are all refused.
  # `typ` is checked only when present; an absent one is not a different
  # algorithm.
  defp check_header(%{"alg" => "ES256K"} = header) do
    case Map.get(header, "typ") do
      nil -> :ok
      "JWT" -> :ok
      _other -> {:error, :invalid_typ}
    end
  end

  defp check_header(_header), do: {:error, :unsupported_alg}

  defp check_claims(claims, audience, lxm) do
    with :ok <- check_audience(claims, audience),
         :ok <- check_method(claims, lxm),
         :ok <- check_expiry(claims),
         :ok <- check_issued_at(claims),
         :ok <- check_not_before(claims) do
      :ok
    end
  end

  defp check_audience(%{"aud" => audience}, audience), do: :ok
  defp check_audience(_claims, _audience), do: {:error, :aud_mismatch}

  defp check_method(%{"lxm" => lxm}, lxm), do: :ok
  defp check_method(_claims, _lxm), do: {:error, :lxm_mismatch}

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_claims), do: {:error, :missing_exp}

  defp check_issued_at(%{"iat" => iat}) when is_integer(iat) do
    if iat <= System.system_time(:second) + @clock_skew_seconds,
      do: :ok,
      else: {:error, :invalid_iat}
  end

  defp check_issued_at(%{"iat" => _iat}), do: {:error, :invalid_iat}
  defp check_issued_at(_claims), do: :ok

  defp check_not_before(%{"nbf" => nbf}) when is_integer(nbf) do
    if nbf <= System.system_time(:second) + @clock_skew_seconds,
      do: :ok,
      else: {:error, :not_yet_valid}
  end

  defp check_not_before(%{"nbf" => _nbf}), do: {:error, :not_yet_valid}
  defp check_not_before(_claims), do: :ok

  defp check_iss(%{"iss" => did}) when is_binary(did), do: {:ok, did}
  defp check_iss(_claims), do: {:error, :missing_iss}

  # The signing key is the verification method whose id ends in #atproto, the
  # fragment the spec reserves for it, whether the id is the full DID or the
  # bare fragment.
  defp atproto_key(%{"verificationMethod" => methods}) when is_list(methods) do
    case Enum.find(methods, &atproto_method?/1) do
      nil -> {:error, :atproto_key_missing}
      method -> method_key(method)
    end
  end

  defp atproto_key(_document), do: {:error, :atproto_key_missing}

  defp atproto_method?(%{"id" => id}) when is_binary(id), do: String.ends_with?(id, "#atproto")
  defp atproto_method?(_method), do: false

  defp method_key(%{"publicKeyMultibase" => multibase}) when is_binary(multibase),
    do: decode_key(multibase)

  defp method_key(_method), do: {:error, :atproto_key_missing}

  # did:key and Multikey are the same multibase bytes with different framing;
  # the legacy EcdsaSecp256k1VerificationKey2019 form drops the multicodec and
  # keeps the key uncompressed. All three reduce to a compressed secp256k1
  # point.
  defp decode_key("did:key:" <> multibase), do: decode_key(multibase)

  defp decode_key(<<?z, encoded::binary>>) do
    with {:ok, bytes} <- base58(encoded) do
      secp256k1_key(bytes)
    end
  end

  defp decode_key(_multibase), do: {:error, :unsupported_key}

  defp base58(encoded) do
    {:ok, Base58.decode!(encoded)}
  rescue
    _error -> {:error, :unsupported_key}
  end

  defp secp256k1_key(<<0xE7, 0x01, key::binary-33>>), do: {:ok, key}

  defp secp256k1_key(<<4, _rest::binary>> = uncompressed) when byte_size(uncompressed) == 65,
    do: {:ok, Secp256k1.compress(uncompressed)}

  defp secp256k1_key(<<prefix, _x::binary-32>> = key) when prefix in [0x02, 0x03], do: {:ok, key}

  defp secp256k1_key(_bytes), do: {:error, :unsupported_key}

  defp check_signature(input, signature, key) when byte_size(signature) == 64 do
    if valid_signature?(input, signature, key), do: :ok, else: {:error, :invalid_signature}
  end

  defp check_signature(_input, _signature, _key), do: {:error, :invalid_signature}

  # A public point that is not on the curve makes :crypto raise rather than
  # answer false, and the point came out of a fetched document, so a raise is
  # answered as a failed verification.
  defp valid_signature?(input, signature, key) do
    :crypto.verify(:ecdsa, :sha256, input, Secp256k1.raw_to_der(signature), [key, :secp256k1])
  rescue
    _error -> false
  end
end
