defmodule Pesque.Identity do
  @moduledoc """
  The server's own identity: a did:web, its handle, and the DID document.

  Stateless. Derivation lives in Pesque.Did, and the server's signing key
  lives in Pesque.Keys like every other key, one file per DID, so the server
  and an account are provisioned the same way.

  This is the identity of did:web:<host> itself. Under conformant_single
  that DID is also the single account's, which is why its key is created
  here at boot rather than by create_account/3.
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

  @doc "The server's own DID, derived from mode, hostname and port."
  def did,
    do: Did.did_for_username(Pesque.mode(), Did.did_host(Pesque.hostname(), Pesque.port()), nil)

  @doc "The handle the server publishes for itself."
  def handle, do: Did.handle_for_username(Pesque.mode(), Pesque.handle_domain(), nil)

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
      pub_multibase: public_key_multibase()
    }
  end
end
