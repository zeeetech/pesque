defmodule Pesque.Identity do
  @moduledoc """
  The server's own identity: a did:web, its signing key, and the DID document.
  Owns the key file; nothing else on the node ever touches it.
  """

  use GenServer

  defstruct [:did, :handle, :hostname, :priv, :pub_multibase, :server_secret]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def did, do: GenServer.call(__MODULE__, :did)
  def handle, do: GenServer.call(__MODULE__, :handle)
  def hostname, do: GenServer.call(__MODULE__, :hostname)
  def server_secret, do: GenServer.call(__MODULE__, :server_secret)
  def did_document, do: GenServer.call(__MODULE__, :did_document)
  def sign(payload), do: GenServer.call(__MODULE__, {:sign, payload})

  @impl true
  def init(_opts) do
    hostname = Pesque.hostname()
    handle = Pesque.handle()
    did = "did:web:" <> hostname

    {pub, priv} = load_or_generate_key()
    multibase = Pesque.Secp256k1.public_key_multibase(pub)
    secret = Pesque.Storage.server_secret!()

    {:ok,
     %__MODULE__{
       did: did,
       handle: handle,
       hostname: hostname,
       priv: priv,
       pub_multibase: multibase,
       server_secret: secret
     }}
  end

  @impl true
  def handle_call(:did, _from, state), do: {:reply, state.did, state}
  def handle_call(:handle, _from, state), do: {:reply, state.handle, state}
  def handle_call(:hostname, _from, state), do: {:reply, state.hostname, state}
  def handle_call(:server_secret, _from, state), do: {:reply, state.server_secret, state}

  def handle_call(:did_document, _from, state) do
    doc = %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/multikey/v1"
      ],
      "id" => state.did,
      "alsoKnownAs" => ["at://" <> state.handle],
      "verificationMethod" => [
        %{
          "id" => state.did <> "#atproto",
          "type" => "Multikey",
          "controller" => state.did,
          "publicKeyMultibase" => state.pub_multibase
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://" <> state.hostname
        }
      ]
    }

    {:reply, doc, state}
  end

  def handle_call({:sign, payload}, _from, state) do
    {:reply, Pesque.Secp256k1.sign(state.priv, payload), state}
  end

  defp load_or_generate_key do
    path = Path.join(Pesque.data_dir(), "signing.key")

    case File.read(path) do
      {:ok, priv} ->
        {Pesque.Secp256k1.public_from_private(priv), priv}

      {:error, _reason} ->
        {pub, priv} = Pesque.Secp256k1.generate_keypair()
        File.mkdir_p!(Pesque.data_dir())
        File.write!(path, priv)
        File.chmod!(path, 0o600)
        {pub, priv}
    end
  end
end
