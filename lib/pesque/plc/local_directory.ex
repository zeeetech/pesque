defmodule Pesque.Plc.LocalDirectory do
  @moduledoc """
  A PLC directory that keeps its operations in a file, for development.

  A did:plc account is registered by submitting a genesis operation to the
  directory, so a development server that signs up or migrates mints a real DID
  in a directory the whole network reads. This writes that operation under the
  data directory instead, and reads it back as the document the directory would
  have built. A DID nothing was written for is asked of the real directory, so
  an account on another server still resolves for real.

  Selected by the development and test configs only. An account minted against
  a local directory resolves to this server and nowhere else, which on a real
  deployment is a silent federation break, so a release never selects it.
  """

  @doc "Writes the operation for `did`, so `resolve/1` can answer it."
  def submit(did, op) when is_binary(did) and is_map(op) do
    with :ok <- File.mkdir_p(dir()),
         :ok <- File.write(path(did), JSON.encode!(op)) do
      :ok
    else
      {:error, reason} -> {:error, {:plc_local_write, reason}}
    end
  end

  @doc """
  The document the directory would answer for `did`.

  A DID this directory was never asked about goes to the real directory, so an
  account on another server still resolves.
  """
  def resolve(did) do
    case read(did) do
      {:ok, op} -> {:ok, document(did, op)}
      :error -> remote().resolve(did)
    end
  end

  # The shape both readers need: `Pesque.DidResolver.normalize/2` requires the id
  # to be the DID itself, and `Pesque.Plc.verify_pds/1` requires the service list
  # to name this server's PDS endpoint.
  defp document(did, op) do
    %{
      "id" => did,
      "service" => [
        %{
          "id" => did <> "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => endpoint(op)
        }
      ]
    }
  end

  defp endpoint(%{"services" => %{"atproto_pds" => %{"endpoint" => endpoint}}})
       when is_binary(endpoint),
       do: endpoint

  # An operation with no endpoint of its own can only have been written here, so
  # the answer is this server rather than a document with no service at all.
  defp endpoint(_op), do: Pesque.service_endpoint()

  defp read(did) do
    with {:ok, body} <- File.read(path(did)),
         {:ok, op} when is_map(op) <- JSON.decode(body) do
      {:ok, op}
    else
      _ -> :error
    end
  end

  defp dir, do: Path.join(Pesque.data_dir(), "plc")

  defp path(did), do: Path.join(dir(), Pesque.Storage.digest_name(did) <> ".json")

  # The real directory, injectable the way Pesque.Plc and Pesque.DidResolver
  # inject theirs, so a test can answer the fall-through without the network.
  defp remote, do: Application.get_env(:pesque, :plc_local_remote, Pesque.Plc.Directory)
end
