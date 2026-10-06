defmodule Pesque.Plc.Keys do
  @moduledoc """
  Key files for a did:plc account: the repo signing key and the rotation key.

  The repo key lives where `Pesque.Keys` looks for it, so the rest of the
  server reads it unchanged. The rotation key is a second file, named apart
  from it, because it is the account's only recovery path and losing it is
  irreversible: without it the DID can never be updated, rotated, or
  tombstoned again. Back up `data/keys` with the rest of the server state, or
  the account is frozen at the operation it last submitted.

  Both files are 0600 inside a 0700 directory, created exclusively, for the
  reasons `Pesque.Keys` gives: two creators racing must not overwrite each
  other, and the mode has to be set before the bytes land.
  """

  alias Pesque.Keys
  alias Pesque.Secp256k1
  alias Pesque.Storage

  @doc "Path of the rotation key file for a DID."
  def rotation_path(did) do
    Path.join(Storage.keys_dir(), Storage.digest_name(did) <> ".rotation.key")
  end

  @doc "Path of the repo signing key file, which is Pesque.Keys'."
  def repo_path(did), do: Keys.path(did)

  @doc "Generates a rotation keypair for a DID and claims its file exclusively."
  def create_rotation(did) do
    {pub, priv} = Secp256k1.generate_keypair()
    create_rotation(did, pub, priv)
  end

  @doc "Writes a pre-generated rotation keypair, claiming its file exclusively."
  def create_rotation(did, pub, priv), do: claim(rotation_path(did), pub, priv)

  @doc "Writes a pre-generated repo keypair, claiming its file exclusively."
  def create_repo(did, pub, priv), do: claim(repo_path(did), pub, priv)

  @doc "Reads the rotation private key for a DID."
  def load_rotation(did), do: File.read(rotation_path(did))

  @doc "Removes both key files for a DID, tolerating either being absent."
  def delete(did) do
    _ = File.rm(rotation_path(did))
    _ = Keys.delete(did)
    :ok
  end

  defp claim(path, pub, priv) do
    case :file.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        # chmod before the bytes, like Pesque.Keys: the file opens with the
        # umask's mode, so the window where it is too wide holds nothing.
        :ok = File.chmod(path, 0o600)
        :ok = :file.write(device, priv)
        :ok = :file.close(device)

        {:ok, %{priv: priv, pub: pub, pub_multibase: Secp256k1.public_key_multibase(pub)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
