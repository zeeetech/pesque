defmodule Pesque.Keys do
  @moduledoc """
  Private signing key files, one per DID.

  The file name is a digest of the DID rather than the DID itself, for the
  reasons given on Storage.digest_name/1.
  """

  alias Pesque.{Secp256k1, Storage}

  @doc "Path of the key file for a DID."
  def path(did) do
    Path.join(Storage.keys_dir(), Storage.digest_name(did) <> ".key")
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
