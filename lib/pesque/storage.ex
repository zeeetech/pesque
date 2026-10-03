defmodule Pesque.Storage do
  @moduledoc "Filesystem bootstrap: data directory, key directory, and the persistent server secret."

  def init! do
    File.mkdir_p!(Pesque.data_dir())
    File.mkdir_p!(keys_dir())
    File.chmod!(keys_dir(), 0o700)
    :ok
  end

  @doc "Directory holding the signing keys."
  def keys_dir, do: Path.join(Pesque.data_dir(), "keys")

  @doc "Reads the server secret from disk, generating and persisting it on first boot."
  def server_secret!(data_dir \\ Pesque.data_dir()) do
    path = Path.join(data_dir, "server.secret")

    case File.read(path) do
      {:ok, secret} ->
        String.trim(secret)

      {:error, _reason} ->
        secret = Base.encode16(:crypto.strong_rand_bytes(64), case: :lower)
        File.mkdir_p!(data_dir)
        File.write!(path, secret)
        File.chmod!(path, 0o600)
        secret
    end
  end
end
