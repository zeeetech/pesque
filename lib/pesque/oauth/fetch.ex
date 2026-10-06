defmodule Pesque.OAuth.Fetch do
  @moduledoc """
  Fetching one JSON document over HTTPS, for a URL a stranger chose.

  This is more than a GET because of SSRF. The URL comes from a client_id, so
  an attacker picks the host, and an authorization server that will fetch any
  host a stranger names is a server that will fetch the cloud metadata address
  or a database on the same network. So the name is resolved before the
  request and every address it answers is refused when it lands anywhere
  private, loopback, link-local or otherwise unroutable.

  What that does not close: the name is resolved twice, once here and once when
  the connection is made, so a name whose answer changes between the two
  answers a checked address here and a private one there. Pinning the
  connection to the checked address closes it, and is not done here because
  httpc does not expose the resolved address to the TLS layer; a client library
  with a resolver hook would. Treat a resolvable client_id as a name this
  server will look up, not one it will refuse to look up twice.

  The rest of the hardening is ordinary: TLS verified, no redirect followed
  (a redirect is a second URL the attacker chose, and would skip the address
  check entirely), a short timeout, and a byte cap on the response.

  `:inets` and `:ssl` rather than a client library: it is OTP, and the request
  is one GET of one small JSON document.
  """

  @connect_timeout 5_000
  @timeout 5_000

  @doc """
  Fetches `uri` and decodes it as a JSON object, capped at `max_bytes`.

  Answers {:ok, map} or {:error, reason}. Every failure is a reason rather
  than an exception: the URL came from a stranger, so every branch here is
  reachable with a crafted string.
  """
  def json(%URI{} = uri, max_bytes) do
    with :ok <- check_scheme(uri),
         :ok <- check_address(uri.host) do
      request(uri, max_bytes)
    end
  end

  defp request(uri, max_bytes) do
    case :httpc.request(
           :get,
           {URI.to_string(uri), [{~c"accept", ~c"application/json"}]},
           [
             connect_timeout: @connect_timeout,
             timeout: @timeout,
             ssl: ssl_options(),
             autoredirect: false
           ],
           []
         ) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        decode(IO.iodata_to_binary(body), max_bytes)

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:client_metadata_status, status}}

      {:error, reason} ->
        {:error, {:client_metadata_unreachable, reason}}
    end
  end

  defp decode(body, max_bytes) do
    if byte_size(body) > max_bytes do
      {:error, :client_metadata_too_large}
    else
      case JSON.decode(body) do
        {:ok, document} when is_map(document) -> {:ok, document}
        _ -> {:error, :invalid_client_metadata}
      end
    end
  end

  defp check_scheme(%URI{scheme: "https"}), do: :ok
  defp check_scheme(_uri), do: {:error, :invalid_client_id}

  defp check_address(host) do
    case resolve(host) do
      [] ->
        {:error, {:client_metadata_unreachable, :nxdomain}}

      addresses ->
        if Enum.all?(addresses, &public_address?/1) do
          :ok
        else
          {:error, :forbidden_address}
        end
    end
  end

  # `:inet_res.lookup/3` with `:a` answers address tuples directly. The four
  # argument form with `:ipv4` is not a query type this OTP accepts: it raises
  # `{:bad_generator, :ipv4}`, which an earlier rescue turned into an empty
  # answer, so every name looked like NXDOMAIN.
  defp resolve(host) do
    :inet_res.lookup(String.to_charlist(host), :in, :a)
  rescue
    _ -> []
  end

  # Anything not routable on the public internet. A client metadata document is
  # published on the public web by definition, so a private answer to the name
  # means the name was chosen to reach something else.
  defp public_address?(tuple) when is_tuple(tuple), do: public?(tuple)
  defp public_address?(_address), do: false

  defp public?({0, _, _, _}), do: false
  defp public?({10, _, _, _}), do: false
  defp public?({100, a, _, _}) when a in 64..127, do: false
  defp public?({127, _, _, _}), do: false
  defp public?({169, 254, _, _}), do: false
  defp public?({172, a, _, _}) when a in 16..31, do: false
  defp public?({192, 0, 0, _}), do: false
  defp public?({192, 0, 2, _}), do: false
  defp public?({192, 168, _, _}), do: false
  defp public?({198, 18, _, _}), do: false
  defp public?({198, 51, 100, _}), do: false
  defp public?({203, 0, 113, _}), do: false
  defp public?({224, _, _, _}), do: false
  defp public?({240, _, _, _}), do: false
  defp public?({_, _, _, _}), do: true

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
