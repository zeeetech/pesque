defmodule Pesque.Identity do
  @moduledoc """
  The server's own identity: a did:web, its handle, and the DID document.

  Stateless. Derivation lives in Pesque.Did, the signing key is read from
  :persistent_term because it is on the commit path and never changes after
  boot, and the server secret is Pesque.Secret's.
  """

  alias Pesque.{Did, Secp256k1}

  @priv {__MODULE__, :priv}
  @pub_multibase {__MODULE__, :pub_multibase}

  @doc "Loads the signing key into :persistent_term. Called once, before the endpoint starts."
  def load! do
    {pub, priv} = load_or_generate_key()
    :persistent_term.put(@priv, priv)
    :persistent_term.put(@pub_multibase, Secp256k1.public_key_multibase(pub))
  end

  def mode, do: Pesque.mode()
  def hostname, do: Pesque.hostname()
  def handle_domain, do: Pesque.handle_domain()
  def did, do: Did.did_for_username(mode(), Did.did_host(hostname(), Pesque.port()), nil)
  def handle, do: Did.handle_for_username(mode(), handle_domain(), nil)
  def service_endpoint, do: Did.service_endpoint(hostname())
  def did_document, do: Did.did_document(mode(), identity())
  def sign(payload), do: Secp256k1.sign(:persistent_term.get(@priv), payload)

  defp identity do
    %{
      username: nil,
      hostname: hostname(),
      port: Pesque.port(),
      handle_domain: handle_domain(),
      pub_multibase: :persistent_term.get(@pub_multibase)
    }
  end

  defp load_or_generate_key do
    path = Pesque.Storage.signing_key_path()

    case File.read(path) do
      {:ok, priv} ->
        {Secp256k1.public_from_private(priv), priv}

      {:error, _reason} ->
        {pub, priv} = Secp256k1.generate_keypair()
        File.mkdir_p!(Pesque.Storage.keys_dir())
        File.write!(path, priv)
        File.chmod!(path, 0o600)
        {pub, priv}
    end
  end
end
