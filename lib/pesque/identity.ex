defmodule Pesque.Identity do
  @moduledoc """
  The server's own identity: its DID, handle, and DID document.

  The server's own DID is always `did:web:<hostname>`. It is the host identity,
  never minted, never persisted to a file, and always served from this process.
  Boot loads the signing key for it; there is no boot-time network call and no
  server identity file.

  Whether an *account* is a did:web or a did:plc is a property of the account,
  decided at creation time (see `Pesque.Accounts.create_account/4` and the
  `--identity` flag). It is not the server's identity and never changes what
  this module answers.
  """

  alias Pesque.Did
  alias Pesque.Keys

  @pub_multibase {__MODULE__, :pub_multibase}

  @doc "Loads the server's signing key. Called once, before the endpoint starts."
  def load! do
    case Keys.ensure(did()) do
      {:ok, key} ->
        :persistent_term.put(@pub_multibase, key.pub_multibase)

      {:error, reason} ->
        raise "the server signing key could not be loaded: #{inspect(reason)}"
    end
  end

  @doc """
  The server's own DID: always `did:web:<hostname>`, in both modes.

  Derived from the hostname and port, never read from a file or the directory.
  """
  def did do
    Did.did_for_username(Pesque.mode(), Did.did_host(Pesque.hostname(), Pesque.port()), nil)
  end

  @doc """
  The handle the server publishes for itself.

  Under single the single account is the bare handle domain, so that is the
  server's handle. Under multi the handle domain is the namespace accounts are
  minted into (`alice.<handle_domain>`), not a name the server holds: the
  server's own handle is its hostname, which leaves the apex of the handle
  domain free for an account.
  """
  def handle do
    case Pesque.mode() do
      :single -> Pesque.handle_domain()
      :multi -> String.downcase(Pesque.hostname())
    end
  end

  @doc "The DID document this server serves for its own DID."
  def did_document, do: Did.did_document(Pesque.mode(), identity())

  @doc "The server signing key in multibase form, as published in that document."
  def public_key_multibase, do: :persistent_term.get(@pub_multibase)

  defp identity do
    %{
      username: nil,
      hostname: Pesque.hostname(),
      port: Pesque.port(),
      handle_domain: Pesque.handle_domain(),
      handle: handle(),
      pub_multibase: public_key_multibase()
    }
  end
end
