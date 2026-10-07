defmodule Pesque.Keys do
  @moduledoc """
  Private signing key files, one per DID.

  The file name is a digest of the DID rather than the DID itself, for the
  reasons given on Storage.digest_name/1.
  """

  alias Pesque.Secp256k1
  alias Pesque.Storage

  @doc "Path of the key file for a DID."
  def path(did) do
    Path.join(Storage.keys_dir(), Storage.digest_name(did) <> ".key")
  end

  @doc """
  Generates a key for a DID and claims its file exclusively.

  Exclusive is the point: two createAccount calls for one handle race here,
  and the loser gets {:error, :eexist} instead of overwriting the winner's
  key with a fresh one the winner has already published.

  The chmod is not a leftover. It cannot be replaced by a mode on the open,
  because Erlang's file:open/2 has no creation-mode option: `{:mode, 0o600}`
  is accepted and ignored, and the file lands 0644 under the umask. A
  descriptor opened in the window between the create and the chmod therefore
  does keep reading the key, and closing that window needs a mode that
  open(2) honours, which this API does not offer. What the ordering buys is
  that the window holds an empty file rather than a private key, and
  keys_dir is 0700 (Storage.init!/1), so a local process that is not this
  user cannot reach the path at all.
  """
  def create_exclusive(did) do
    {pub, priv} = Secp256k1.generate_keypair()

    case write(path(did), priv) do
      {:ok, _path} ->
        {:ok, %{priv: priv, pub: pub, pub_multibase: Secp256k1.public_key_multibase(pub)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reads the private key for a DID."
  def load(did), do: File.read(path(did))

  @doc """
  Reads the key for a DID, generating one when the file is absent.

  A repo whose DID was never provisioned through create_account/4 would
  otherwise have no key to sign with, and refusing to start is worse than
  minting one: an unpublished key still yields a repo nobody can verify.

  A key that exists but cannot be read answers {:error, {:key_unreadable, path, reason}}
  rather than raising, so a caller decides whether that is a boot failure or
  something to log and keep going.
  """
  def ensure(did) do
    case load(did) do
      {:ok, priv} ->
        {:ok, keypair(priv)}

      {:error, :enoent} ->
        create_exclusive(did)

      {:error, reason} ->
        {:error, {:key_unreadable, path(did), reason}}
    end
  end

  @doc "Removes the key file for a DID."
  def delete(did), do: File.rm(path(did))

  @doc "`publicKeyMultibase` for a private key."
  def public_key_multibase(priv) do
    Secp256k1.public_key_multibase(Secp256k1.public_from_private(priv))
  end

  defp write(path, priv), do: Storage.write_private(path, priv)

  defp keypair(priv) do
    pub = Secp256k1.public_from_private(priv)
    %{priv: priv, pub: pub, pub_multibase: Secp256k1.public_key_multibase(pub)}
  end
end
