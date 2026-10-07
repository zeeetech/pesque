defmodule Pesque.Identity do
  @moduledoc """
  The server's own identity: its DID, handle, and DID document.

  The DID method follows the mode. Under did:web it is derived from the
  hostname, and the key lives in Pesque.Keys like every other key. Under
  conformant_single with identity = plc the server's own did:plc is minted
  once through the directory and persisted to a file, because the Repo is not
  running yet when load!/0 runs. Either way the signing key is one file per
  DID, so the server and an account are provisioned the same way.
  """

  alias Pesque.Did
  alias Pesque.Keys
  alias Pesque.Plc
  alias Pesque.Storage

  @pub_multibase {__MODULE__, :pub_multibase}
  @server_did {__MODULE__, :server_did}
  @server_operation {__MODULE__, :server_operation}

  @doc "Loads the server's signing key. Called once, before the endpoint starts."
  def load! do
    case {Pesque.mode(), Pesque.identity()} do
      {:conformant_single, :plc} -> load_plc_identity()
      _other -> load_web_identity()
    end
  end

  # The default identity: a did:web derived from the hostname, keyed like any
  # other account. Nothing here touches the network or the database.
  defp load_web_identity do
    case Keys.ensure(did()) do
      {:ok, key} ->
        :persistent_term.put(@pub_multibase, key.pub_multibase)

      {:error, reason} ->
        raise "the server signing key could not be loaded: #{inspect(reason)}"
    end
  end

  # The single account is the server, so its DID is the server's own. Under plc
  # that DID is minted once through the directory and persisted to a file: the
  # Repo is not running yet at load!/0 time, so the meta table is not reachable
  # and the file is the only place this can live.
  defp load_plc_identity do
    case Storage.read_server_identity() do
      {:ok, %{"did" => did, "operation" => operation}} ->
        cache_server_identity(did, operation)
        cache_pub_multibase(Keys.ensure(did))

      {:error, :enoent} ->
        mint_server_identity()

      {:error, reason} ->
        raise "the server identity file could not be read: #{inspect(reason)}"
    end
  end

  # Minted once, then written before it is cached: a server that could not
  # persist the DID would mint a fresh one on the next boot and orphan the
  # first at the directory, so a write failure fails boot instead.
  defp mint_server_identity do
    case Plc.mint(handle()) do
      {:ok, %{did: did, key: key, operation: operation}} ->
        case Storage.write_server_identity(%{"did" => did, "operation" => operation}) do
          {:ok, _path} ->
            cache_server_identity(did, operation)
            :persistent_term.put(@pub_multibase, key.pub_multibase)

          {:error, reason} ->
            raise "the server identity could not be persisted: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "the server did:plc could not be minted: #{inspect(reason)}"
    end
  end

  defp cache_server_identity(did, operation) do
    :persistent_term.put(@server_did, did)
    :persistent_term.put(@server_operation, operation)
  end

  defp cache_pub_multibase({:ok, key}),
    do: :persistent_term.put(@pub_multibase, key.pub_multibase)

  defp cache_pub_multibase({:error, reason}),
    do: raise("the server signing key could not be loaded: #{inspect(reason)}")

  @doc """
  The server's own DID.

  Derived from mode, hostname and port under did:web; the DID minted at boot
  and cached under `conformant_single` with `identity = plc`.
  """
  def did do
    case {Pesque.mode(), Pesque.identity()} do
      {:conformant_single, :plc} ->
        :persistent_term.get(@server_did)

      _other ->
        Did.did_for_username(Pesque.mode(), Did.did_host(Pesque.hostname(), Pesque.port()), nil)
    end
  end

  @doc "The handle the server publishes for itself."
  def handle, do: Did.handle_for_username(Pesque.mode(), Pesque.handle_domain(), nil)

  @doc "The DID document this server serves for its own DID."
  def did_document, do: Did.did_document(Pesque.mode(), identity())

  @doc "The server signing key in multibase form, as published in that document."
  def public_key_multibase, do: :persistent_term.get(@pub_multibase)

  @doc "The signed PLC operation that registered the server's did:plc, or nil under did:web."
  def server_operation, do: :persistent_term.get(@server_operation, nil)

  defp identity do
    %{
      username: nil,
      hostname: Pesque.hostname(),
      port: Pesque.port(),
      handle_domain: Pesque.handle_domain(),
      pub_multibase: public_key_multibase()
    }
  end
end
