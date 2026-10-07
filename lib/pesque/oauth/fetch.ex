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

  Three more gaps matter now that the entryway relies on this guard for a
  second caller. The lookup asks for A records only, so a host that publishes
  only an AAAA answer resolves to nothing here and is refused as unreachable.
  Response headers have no size cap: `max_header_size` is not available before
  OTP 29.0.6, and this server pins 28.1. And a response that declares no length
  is delimited by the connection closing, so the byte cap is the only bound on
  how much is read rather than a length the transport stops at.

  The rest of the hardening is ordinary: TLS verified, no redirect followed
  (a redirect is a second URL the attacker chose, and would skip the address
  check entirely), a short timeout, and a byte cap on the response.

  `:inets` and `:ssl` rather than a client library: it is OTP, and the request
  is one GET of one small JSON document.
  """

  @connect_timeout 5_000
  @timeout 5_000

  # The default cap for request/5. Callers that know their own bound pass one;
  # this is what a request with none gets.
  @default_max_bytes 10 * 1024 * 1024

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

  @doc """
  Posts `body` as a JSON document to `uri`.

  Answers :ok on a 2xx and {:error, reason} otherwise. The scheme and address
  checks of json/2 are kept: the URL here is the PLC directory base from
  configuration rather than a stranger's string, but one outbound path with
  one set of rules is worth more than a second unchecked one.
  """
  def post_json(%URI{} = uri, body) do
    with :ok <- hardened(uri) do
      post(uri, JSON.encode!(body))
    end
  end

  @doc """
  Fetches `uri` with the same hardening as json/2 and answers the raw response.

  Answers {:ok, status, headers, body} or {:error, reason}. Unlike json/2 a
  status outside 2xx is a successful answer here: this is the primitive, and
  the caller decides what a status means. The body is capped at `max_bytes`.
  """
  def get(%URI{} = uri, max_bytes) do
    with :ok <- check_scheme(uri),
         :ok <- check_address(uri.host) do
      raw_get(uri, max_bytes)
    end
  end

  @doc """
  Makes one HTTP request with the same hardening as json/2 and answers the raw
  response.

  Answers `{:ok, status, headers, body}` or `{:error, reason}`. Like get/2, a
  status outside 2xx is a successful answer: the caller decides what a status
  means. `opts` carries `:max_bytes` (also handed to `:httpc` as
  `max_body_size`), `:connect_timeout` and `:timeout`. The body is capped both
  by `:httpc` and by a post-hoc byte-size check, so an answer that slips past
  the transport cap is still refused.
  """
  @spec request(URI.t(), :get | :post, [{String.t(), String.t()}], binary() | nil, keyword()) ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def request(%URI{} = uri, method, headers, body, opts \\ []) do
    with :ok <- check_scheme(uri),
         :ok <- check_address(uri.host) do
      send(uri, method, headers, body, Keyword.get(opts, :max_bytes, @default_max_bytes), opts)
    end
  end

  defp send(uri, method, headers, body, max_bytes, opts) do
    {content_type, headers} = split_content_type(headers)

    request =
      case method do
        :get -> {URI.to_string(uri), charlist_headers(headers)}
        :post -> {URI.to_string(uri), charlist_headers(headers), to_charlist(content_type), body}
      end

    options = httpc_options(opts) |> Keyword.put(:max_body_size, max_bytes)

    case :httpc.request(method, request, options, []) do
      {:ok, {{_v, status, _r}, resp_headers, resp_body}} ->
        body = IO.iodata_to_binary(resp_body)

        if byte_size(body) > max_bytes,
          do: {:error, :body_too_large},
          else: {:ok, status, normalize_headers(resp_headers), body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The content-type is a header like any other to :httpc's tuple form, which
  # takes it as the third element of a POST. It is pulled out here rather than
  # added by the caller so one header list works for both verbs.
  defp split_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_name, value} -> {value, List.keydelete(headers, "content-type", 0)}
      nil -> {"application/json", headers}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp hardened(uri) do
    with :ok <- check_scheme(uri),
         :ok <- check_address(uri.host) do
      :ok
    else
      {:error, _reason} -> {:error, :plc_unreachable}
    end
  end

  defp post(uri, body) do
    case :httpc.request(
           :post,
           {URI.to_string(uri), [{~c"accept", ~c"application/json"}], ~c"application/json", body},
           httpc_options(),
           []
         ) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:plc_status, status}}

      {:error, reason} ->
        {:error, {:plc_unreachable, reason}}
    end
  end

  defp raw_get(uri, max_bytes) do
    case :httpc.request(
           :get,
           {URI.to_string(uri), [{~c"accept", ~c"application/json"}]},
           httpc_options(),
           []
         ) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        body = IO.iodata_to_binary(body)

        if byte_size(body) > max_bytes do
          {:error, :client_metadata_too_large}
        else
          {:ok, status, headers, body}
        end

      {:error, reason} ->
        {:error, {:client_metadata_unreachable, reason}}
    end
  end

  defp request(uri, max_bytes) do
    case :httpc.request(
           :get,
           {URI.to_string(uri), [{~c"accept", ~c"application/json"}]},
           httpc_options(),
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

  # The one request shape every outbound call uses: TLS verified, no redirect
  # followed (a redirect is a second URL the attacker chose, and would skip the
  # address check entirely), and a short timeout. `opts` widens the two
  # timeouts for a caller that needs to; the zero-arity form is the default.
  defp httpc_options(opts \\ []) do
    [
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout),
      timeout: Keyword.get(opts, :timeout, @timeout),
      ssl: ssl_options(),
      autoredirect: false
    ]
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
