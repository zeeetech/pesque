defmodule Pesque.Entryway do
  @moduledoc """
  Forwarding an XRPC call to the service a client named with atproto-proxy.

  This is the shell around `Pesque.Entryway.Proxy`: it resolves the target DID,
  finds the named service in its document, mints a service-auth token for the
  authenticated account, and makes the call. Every failure is normalized to a
  reason `PesqueWeb.Xrpc.Errors` knows, and the upstream's own status is never
  translated here: a non-2xx from the target is passed through untouched.

  Both outbound hops are guarded. The DID resolution goes through
  `Pesque.DidResolver`, and the proxied call through `Pesque.OAuth.Fetch`'s
  SSRF check: https only, no redirect followed, a byte cap, and a refused
  address when the name answers anything private.
  """

  alias Pesque.DidResolver
  alias Pesque.Entryway.{Call, Outbound, Proxy, Response}
  alias Pesque.ServiceAuth

  @connect_timeout 5_000

  @doc """
  Forwards `call` on behalf of `did`, the authenticated account.

  Answers `{:ok, %Response{}}` with the upstream's answer, or `{:error, reason}`
  for anything that stopped the call before the target answered.
  """
  @spec forward(Call.t(), String.t()) :: {:ok, Response.t()} | {:error, term()}
  def forward(%Call{} = call, did) when is_binary(did) do
    with {:ok, target} <- Proxy.parse_header(call.proxy),
         true <- Proxy.valid_nsid?(call.nsid) || {:error, :invalid_nsid},
         {:ok, document} <- resolve(target.did),
         {:ok, endpoint} <- Proxy.select_service(document, target.service_id),
         {:ok, token} <- mint(did, target.did, call.nsid),
         outbound =
           Proxy.build_outbound(%{
             method: call.method,
             nsid: call.nsid,
             endpoint: endpoint,
             query: call.query,
             body: call.body,
             token: token,
             headers: call.headers
           }),
         {:ok, response} <- fetch(outbound) do
      {:ok, response}
    end
  end

  defp resolve(did) do
    case DidResolver.resolve(did) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, :proxy_target_unresolved}
    end
  end

  defp mint(did, aud, nsid) do
    case ServiceAuth.mint(did, aud, lxm: nsid) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, :service_auth_failed}
    end
  end

  defp fetch(%Outbound{} = outbound) do
    opts = [
      max_bytes: Pesque.proxy_response_limit(),
      connect_timeout: @connect_timeout,
      timeout: Pesque.proxy_timeout()
    ]

    case fetch_module().request(
           outbound.uri,
           outbound.method,
           outbound.headers,
           outbound.body,
           opts
         ) do
      {:ok, status, headers, body} ->
        {:ok, %Response{status: status, headers: headers, body: body}}

      {:error, reason} ->
        {:error, normalize(reason)}
    end
  end

  defp fetch_module, do: Application.get_env(:pesque, :entryway_fetch, Pesque.OAuth.Fetch)

  defp normalize(:forbidden_address), do: :proxy_forbidden_address
  defp normalize(:body_too_big), do: :proxy_response_too_large
  defp normalize(:body_too_large), do: :proxy_response_too_large
  defp normalize(:timeout), do: :proxy_timeout
  defp normalize({:timeout, _}), do: :proxy_timeout
  defp normalize(:invalid_client_id), do: :invalid_service_endpoint
  defp normalize({:client_metadata_unreachable, _}), do: :proxy_unreachable
  defp normalize(_reason), do: :proxy_unreachable
end
