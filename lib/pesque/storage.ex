defmodule Pesque.Storage do
  @moduledoc "Filesystem bootstrap: data directory, key and blob directories, and the persistent server secret."

  def init! do
    File.mkdir_p!(Pesque.data_dir())
    File.mkdir_p!(keys_dir())
    File.chmod!(keys_dir(), 0o700)
    File.mkdir_p!(blobs_dir())
    :ok
  end

  @doc "Directory holding the signing keys."
  def keys_dir, do: Path.join(Pesque.data_dir(), "keys")

  @doc "Directory holding the blob bytes."
  def blobs_dir, do: Path.join(Pesque.data_dir(), "blobs")

  @doc """
  A filesystem-safe name for a DID.

  A DID is not a filename. Its characters include colons, and on a host with
  a port it includes a percent-encoded colon, and sanitizing either of those
  out merges distinct DIDs onto one file: did:web:example.com:user:alice and
  did:web:example.com:user:alice%3Afoo differ only in a character a path
  segment cannot carry. Two accounts would then share one key file and each
  would publish a key it does not sign with, so the name is a digest of the
  DID instead. The digest is not reversible, which costs nothing here: the DID
  lives in the users table, and a file is only ever looked up by DID.
  """
  def digest_name(did), do: Base.url_encode64(:crypto.hash(:sha256, did), padding: false)

  @doc "Reads the server secret from disk, generating and persisting it on first boot."
  def server_secret!(data_dir \\ Pesque.data_dir()) do
    path = Path.join(data_dir, "server.secret")

    case File.read(path) do
      {:ok, secret} ->
        String.trim(secret)

      {:error, _reason} ->
        secret = Base.encode16(:crypto.strong_rand_bytes(64), case: :lower)
        File.mkdir_p!(data_dir)
        {:ok, device} = :file.open(path, [:write])
        # chmod before the secret bytes land in the file: open(2) creates
        # it with the default mode, so writing first would leave the
        # secret world-readable until the chmod.
        :ok = File.chmod(path, 0o600)
        :ok = :file.write(device, secret)
        :ok = :file.close(device)
        secret
    end
  end
end
