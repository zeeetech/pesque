defmodule Pesque.OAuth.Keys do
  @moduledoc """
  The OAuth signing key: P-256, one file, loaded once at boot.

  This is a second key, and deliberately not the one in Pesque.Keys. That one
  is secp256k1 because ATProto commits are, and it is published in the
  account's DID document, where a consumer verifies it against the account.
  OAuth wants the opposite on both counts: DPoP proofs are signed ES256, and
  the authorization server publishes an EC key in a JWKS for the bearer of a
  token to check. Reusing the commit key would put a repository signing key in
  a token verification path and hand secp256k1 to clients that only implement
  P-256, so the two key purposes never share a file: this one is
  `oauth.p256.key`, the other is named after the DID it signs for.

  The key belongs to the server rather than to an account, so the file name is
  fixed instead of being a digest of a DID, and its private half never leaves
  this module.
  """

  alias Pesque.OAuth.Jwt
  alias Pesque.Storage

  @file_name "oauth.p256.key"
  @key {__MODULE__, :key}

  @doc "Path of the OAuth signing key file."
  def path, do: Path.join(Storage.keys_dir(), @file_name)

  @doc """
  Loads the key, generating it on first boot, and publishes the JWKS.

  Raises when the key cannot be read: a server that cannot sign an access
  token cannot be an authorization server, and serving one anyway would mint
  tokens nobody could verify.
  """
  def load! do
    case ensure() do
      {:ok, key} ->
        :persistent_term.put(@key, key)

      {:error, reason} ->
        raise "the oauth signing key could not be loaded: #{inspect(reason)}"
    end
  end

  @doc """
  The key, generating and persisting it when the file is absent.

  Exclusive, like Pesque.Keys: two nodes booting on one shared volume must not
  both mint a key and publish whichever one they happened to load.
  """
  def ensure do
    case File.read(path()) do
      {:ok, priv} -> {:ok, keypair(priv)}
      {:error, :enoent} -> create_exclusive()
      {:error, reason} -> {:error, {:key_unreadable, reason}}
    end
  end

  @doc "The loaded key. Raises when load!/0 has not run."
  def keypair, do: :persistent_term.get(@key)

  @doc "The public JWK this server publishes, with its kid."
  def jwk do
    %{pub: pub} = keypair()
    core = Jwt.public_jwk(pub)

    core
    |> Map.put("kid", Jwt.thumbprint(core))
    |> Map.put("use", "sig")
    |> Map.put("alg", "ES256")
  end

  @doc "The JWKS document, which is the JWK inside a `keys` array."
  def jwks, do: %{"keys" => [jwk()]}

  @doc """
  The key identifier: the RFC 7638 thumbprint of the public key.

  Derived rather than random, so a restored key keeps the identifier clients
  already cached, and so the JWKS identifier is a function of the key it names.
  """
  def kid do
    %{pub: pub} = keypair()
    pub |> Jwt.public_jwk() |> Jwt.thumbprint()
  end

  @doc "Signs `claims` into an ES256 compact JWS under the published key."
  def sign(claims) do
    %{priv: priv} = keypair()
    Jwt.sign_es256(claims, priv, kid())
  end

  defp create_exclusive do
    case :file.open(path(), [:write, :exclusive]) do
      {:ok, device} -> {:ok, write(device)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(device) do
    {_pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)

    # The file opens with the default mode, so tighten it before the key bytes
    # land in it: the brief 0644 moment holds an empty file.
    :ok = File.chmod(path(), 0o600)
    :ok = :file.write(device, priv)
    :ok = :file.close(device)

    keypair(priv)
  end

  defp keypair(priv) do
    {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256r1, priv)
    %{priv: priv, pub: pub}
  end
end
