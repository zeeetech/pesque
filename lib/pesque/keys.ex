defmodule Pesque.Keys do
  @moduledoc """
  Private signing key files, one per DID.

  A DID is not a filename. Its characters include colons, and on a host with
  a port it includes a percent-encoded colon, and sanitizing either of those
  out merges distinct DIDs onto one file: did:web:example.com:user:alice and
  did:web:example.com:user:alice%3Afoo differ only in a character a path
  segment cannot carry. Two accounts would then share one key file and each
  would publish a key it does not sign with, so the name is a digest of the
  DID instead. The digest is not reversible, which costs nothing here: the
  DID lives in the users table, and a file is only ever looked up by DID.
  """

  alias Pesque.{Secp256k1, Storage}

  @doc "Path of the key file for a DID."
  def path(did) do
    name = Base.url_encode64(:crypto.hash(:sha256, did), padding: false)
    Path.join(Storage.keys_dir(), name <> ".key")
  end

  @doc """
  Generates a key for a DID and claims its file exclusively.

  Exclusive is the point: two createAccount calls for one handle race here,
  and the loser gets {:error, :eexist} instead of overwriting the winner's
  key with a fresh one the winner has already published.
  """
  def create_exclusive(did) do
    case :file.open(path(did), [:write, :exclusive]) do
      {:ok, device} -> {:ok, write(did, device)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads the private key for a DID."
  def load(did), do: File.read(path(did))

  @doc """
  Reads the key for a DID, generating one when the file is absent.

  A repo whose DID was never provisioned through create_account/3 would
  otherwise have no key to sign with, and refusing to start is worse than
  minting one: an unpublished key still yields a repo nobody can verify.
  """
  def ensure(did) do
    case load(did) do
      {:ok, priv} -> {:ok, keypair(priv)}
      {:error, _reason} -> create_exclusive(did)
    end
  end

  @doc "Removes the key file for a DID."
  def delete(did), do: File.rm(path(did))

  @doc "`publicKeyMultibase` for a private key."
  def public_key_multibase(priv) do
    Secp256k1.public_key_multibase(Secp256k1.public_from_private(priv))
  end

  defp write(did, device) do
    {pub, priv} = Secp256k1.generate_keypair()

    :ok = :file.write(device, priv)
    :ok = :file.close(device)
    :ok = File.chmod(path(did), 0o600)

    %{priv: priv, pub: pub, pub_multibase: Secp256k1.public_key_multibase(pub)}
  end

  defp keypair(priv) do
    pub = Secp256k1.public_from_private(priv)
    %{priv: priv, pub: pub, pub_multibase: Secp256k1.public_key_multibase(pub)}
  end
end
