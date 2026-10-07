defmodule Pesque.Entryway.Proxy do
  @moduledoc """
  The pure half of the entryway: turn a client's proxy header and a target DID
  document into an outbound request description. No IO, no process, no config.
  """

  alias Pesque.Entryway.Outbound

  @nsid ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/
  @service_id ~r/\A[a-zA-Z0-9._:%-]{1,64}\z/

  @drop ~w(host content-length connection transfer-encoding expect authorization cookie atproto-proxy accept-encoding)

  @type target :: %{did: String.t(), service_id: String.t()}

  @doc """
  Parses the `atproto-proxy` header into the DID and the service fragment it
  names. A missing header is `:missing_proxy`; anything that is not a
  `did#serviceId` reference is `:invalid_proxy`.
  """
  @spec parse_header(String.t() | nil) ::
          {:ok, target} | {:error, :missing_proxy | :invalid_proxy}
  def parse_header(nil), do: {:error, :missing_proxy}

  def parse_header(value) when is_binary(value) do
    case value |> String.trim() |> String.split("#", parts: 2) do
      [did, service_id] ->
        if valid_did?(did) and Regex.match?(@service_id, service_id),
          do: {:ok, %{did: did, service_id: service_id}},
          else: {:error, :invalid_proxy}

      _no_fragment ->
        {:error, :invalid_proxy}
    end
  end

  def parse_header(_value), do: {:error, :invalid_proxy}

  defp valid_did?(did), do: String.starts_with?(did, "did:") and byte_size(did) <= 2048

  @doc "Whether `nsid` is an XRPC method name."
  @spec valid_nsid?(String.t()) :: boolean()
  def valid_nsid?(nsid) when is_binary(nsid), do: Regex.match?(@nsid, nsid)
  def valid_nsid?(_nsid), do: false

  @doc """
  Finds the service named by `service_id` in a DID document and answers its
  endpoint. The id matches either the full DID plus fragment or the bare
  fragment, which is what the document may carry.
  """
  @spec select_service(map(), String.t()) ::
          {:ok, URI.t()} | {:error, :service_not_found | :invalid_service_endpoint}
  def select_service(document, service_id) when is_map(document) do
    case find(document, service_id) do
      %{"serviceEndpoint" => endpoint} -> endpoint(endpoint)
      nil -> {:error, :service_not_found}
      _other -> {:error, :invalid_service_endpoint}
    end
  end

  def select_service(_document, _service_id), do: {:error, :service_not_found}

  defp find(%{"service" => services}, service_id) when is_list(services) do
    Enum.find(services, fn
      %{"id" => id} when is_binary(id) -> String.ends_with?(id, "#" <> service_id)
      _service -> false
    end)
  end

  defp find(_document, _service_id), do: nil

  defp endpoint(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host} = uri} when is_binary(host) and host != "" ->
        {:ok, uri}

      _other ->
        {:error, :invalid_service_endpoint}
    end
  end

  defp endpoint(_url), do: {:error, :invalid_service_endpoint}

  @doc """
  Builds the outbound request: the endpoint merged with the method path and
  query, the client's headers with the hop-by-hop and authority ones dropped,
  and the service token in place of the client's own authorization.
  """
  @spec build_outbound(map()) :: Outbound.t()
  def build_outbound(%{
        method: method,
        nsid: nsid,
        endpoint: endpoint,
        query: query,
        body: body,
        token: token,
        headers: client_headers
      }) do
    %Outbound{
      method: method,
      uri: outbound_uri(endpoint, nsid, query),
      headers: outbound_headers(client_headers, token),
      body: body
    }
  end

  defp outbound_uri(endpoint, nsid, query) do
    uri = URI.merge(endpoint, "/xrpc/" <> nsid)
    if query in [nil, ""], do: uri, else: %{uri | query: query}
  end

  defp outbound_headers(client_headers, token) do
    client_headers
    |> Enum.reject(fn {name, _v} -> String.downcase(name) in @drop end)
    |> put("authorization", "Bearer " <> token)
    |> put_new("accept", "application/json")
  end

  defp put(headers, name, value), do: List.keystore(headers, name, 0, {name, value})
  defp put_new(headers, name, value), do: List.keystore(headers, name, 0, {name, value})
end
