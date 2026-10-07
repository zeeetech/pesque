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

  @doc "Path of the persisted server identity: the server's own did:plc and its operation."
  def server_identity_path, do: Path.join(Pesque.data_dir(), "server.identity.json")

  @doc """
  Reads the persisted server identity.

  Answers `{:ok, %{"did" => did, "operation" => operation}}`, or
  `{:error, :enoent}` when nothing has been minted yet. The DID and the
  operation are public (the operation is on plc.directory), so this is an
  ordinary read: no mode dance like `write_private/2`, which exists for key
  material.
  """
  def read_server_identity do
    case File.read(server_identity_path()) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"did" => _did, "operation" => _operation} = identity} ->
            {:ok, identity}

          _other ->
            {:error, :invalid_server_identity}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persists the server's minted did:plc so the next boot reuses it.

  Written before the value is cached, so a write that fails fails boot rather
  than leaving a process that believes it persisted an identity it did not.
  """
  def write_server_identity(%{"did" => _did, "operation" => _operation} = identity) do
    File.mkdir_p!(Pesque.data_dir())
    path = server_identity_path()

    case File.write(path, JSON.encode!(identity)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

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

  @doc """
  Writes `bytes` to `path` exclusively, with the mode set before they land.

  The chmod is not a leftover. Erlang's `file:open/2` has no creation-mode
  option: the file opens with the umask's mode, and a descriptor opened in the
  window between the create and the chmod keeps reading it. Chmodming first
  means that window holds an empty file rather than a private key. The open is
  `:exclusive`, so two writers racing for one path get `{:error, :eexist}`
  rather than overwriting each other.
  """
  def write_private(path, bytes) do
    case :file.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        :ok = File.chmod(path, 0o600)
        :ok = :file.write(device, bytes)
        :ok = :file.close(device)
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
