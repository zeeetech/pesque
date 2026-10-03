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

  alias Pesque.{Did, Keys}

  @pub_multibase {__MODULE__, :pub_multibase}

  @doc "Loads the server's signing key. Called once, before the endpoint starts."
  def load! do
    {:ok, key} = Keys.ensure(did())
    :persistent_term.put(@pub_multibase, key.pub_multibase)
  end

  def mode, do: Pesque.mode()
  def hostname, do: Pesque.hostname()
  def handle_domain, do: Pesque.handle_domain()
  def did, do: Did.did_for_username(mode(), Did.did_host(hostname(), Pesque.port()), nil)
  def handle, do: Did.handle_for_username(mode(), handle_domain(), nil)
  def service_endpoint, do: Did.service_endpoint(hostname())
  def did_document, do: Did.did_document(mode(), identity())
  def public_key_multibase, do: :persistent_term.get(@pub_multibase)

  defp identity do
    %{
      username: nil,
      hostname: hostname(),
      port: Pesque.port(),
      handle_domain: handle_domain(),
      pub_multibase: public_key_multibase()
    }
  end
end
