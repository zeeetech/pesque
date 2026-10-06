defmodule Pesque.Plc do
  @moduledoc """
  did:plc account minting and updates against the PLC directory.

  Opt-in through `PDS_IDENTITY=plc`. Under the default `PDS_IDENTITY=web`
  nothing here runs: accounts are did:web, `Pesque.Accounts` never calls into
  this module, and every code path below is dead.

  A freshly minted account is registered with the directory before its row is
  written. If the submission fails nothing is persisted: the caller gets an
  error, the key files are removed, and no account exists. A row whose DID does
  not resolve would make `checkAccountStatus` and `getRepoStatus` lie about an
  account nobody can reach, so there is no half-created state to recover from.
  The cost of that choice is the opposite edge: a createAccount that loses a
  handle race after its operation was accepted leaves an orphan DID at the
  directory. It resolves to a document naming this server, but no row here
  serves it. That is a smaller lie than a row that resolves to nothing, and the
  handle unique index still admits exactly one account.

  The rotation key is the account's only recovery path and is not recoverable
  from the operation log; see `Pesque.Plc.Keys`.
  """

  alias Pesque.Accounts.User
  alias Pesque.Did
  alias Pesque.Plc.Directory
  alias Pesque.Plc.Keys
  alias Pesque.Plc.Operation
  alias Pesque.Secp256k1

  @doc "Whether accounts are minted as did:plc."
  def enabled?, do: Pesque.identity() == :plc

  @doc """
  Mints a did:plc identity for a handle: repo and rotation keys, a signed
  genesis operation, and the DID the directory registered.

  Answers `{:ok, %{did:, key:, operation:}}`, where `operation` is the signed
  operation as JSON for the account row. On any failure the key files are
  removed, so a failed mint leaves nothing behind and the caller writes no row.
  """
  def mint(handle) do
    {repo_pub, repo_priv} = Secp256k1.generate_keypair()
    {rotation_pub, rotation_priv} = Secp256k1.generate_keypair()

    attrs = %{
      signing_key: Did.key_did(repo_pub),
      rotation_keys: [Did.key_did(rotation_pub)],
      handle: handle,
      pds: Did.service_endpoint(Pesque.hostname())
    }

    {op, did} = Operation.genesis(attrs, rotation_priv)

    with {:ok, key} <- claim_keys(did, repo_pub, repo_priv, rotation_pub, rotation_priv),
         :ok <- submit(did, op) do
      {:ok, %{did: did, key: key, operation: JSON.encode!(op)}}
    else
      {:error, reason} ->
        Keys.delete(did)
        {:error, reason}
    end
  end

  @doc """
  Writes a handle change to a did:plc account's operation log.

  Answers `{:ok, operation_json}` or `{:error, reason}`. The caller updates its
  row only after this succeeds: a handle this server resolves but the DID
  document does not claim would resolve to nothing for everyone else.
  """
  def update_handle(%User{did: did, plc_operation: stored}, handle) do
    with {:ok, prev} <- decode_operation(stored),
         {:ok, rotation_priv} <- load_rotation(did),
         op = Operation.update(prev, handle, rotation_priv),
         :ok <- submit(did, op) do
      {:ok, JSON.encode!(op)}
    end
  end

  @doc """
  Verifies a did:plc account's document points at this server's PDS endpoint.

  Answers :ok, or `{:error, :pds_mismatch}` when the document names another
  server, or `{:error, :plc_unreachable}` when the directory cannot be reached.
  A did:web account needs no such check: its document is served here and
  derived from this server's own hostname.
  """
  def verify_pds(did) do
    with {:ok, document} <- client().resolve(did),
         {:ok, endpoint} <- pds_endpoint(document) do
      if endpoint == Did.service_endpoint(Pesque.hostname()) do
        :ok
      else
        {:error, :pds_mismatch}
      end
    end
  end

  defp submit(did, op), do: client().submit(did, op)

  defp client, do: Application.get_env(:pesque, :plc_client, Directory)

  defp claim_keys(did, repo_pub, repo_priv, rotation_pub, rotation_priv) do
    with {:ok, key} <- Keys.create_repo(did, repo_pub, repo_priv),
         {:ok, _rotation} <- Keys.create_rotation(did, rotation_pub, rotation_priv) do
      {:ok, key}
    end
  end

  defp decode_operation(nil), do: {:error, :plc_operation_missing}

  defp decode_operation(stored) do
    case JSON.decode(stored) do
      {:ok, op} when is_map(op) -> {:ok, op}
      _ -> {:error, :plc_operation_missing}
    end
  end

  defp load_rotation(did) do
    case Keys.load_rotation(did) do
      {:ok, priv} -> {:ok, priv}
      {:error, reason} -> {:error, {:rotation_key_unreadable, reason}}
    end
  end

  defp pds_endpoint(%{"service" => services}) when is_list(services) do
    case Enum.find(services, &pds_service?/1) do
      %{"serviceEndpoint" => endpoint} when is_binary(endpoint) -> {:ok, endpoint}
      _ -> {:error, :pds_missing}
    end
  end

  defp pds_endpoint(_document), do: {:error, :pds_missing}

  defp pds_service?(%{"id" => id, "type" => "AtprotoPersonalDataServer"}) when is_binary(id),
    do: String.ends_with?(id, "#atproto_pds")

  defp pds_service?(_service), do: false
end
