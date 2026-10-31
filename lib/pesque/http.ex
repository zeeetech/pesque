defmodule Pesque.HTTP do
  @moduledoc """
  One outbound HTTP request, and the raw response.

  This is the transport every outbound caller shares: the request is sent with
  TLS verified, redirects not followed unless a caller asks for them, and the
  two timeouts bounded. It holds no opinion about the URL or the status, so the
  checks a stranger-named URL needs, the redirect policy, the byte cap a
  particular body wants, and the decoding of it all stay in the callers that
  own them. `Pesque.OAuth.Fetch` is the guarded caller the OAuth, PLC, DID and
  entryway paths go through; the raw callers (`Pesque.Doctor`, the lexicon sync
  task) use this directly.

  `:inets` and `:ssl` rather than a client library: it is OTP, and the requests
  are small. Both are started by the application, so this module does not start
  them itself.

  Answers `{:ok, status, headers, body}` or `{:error, reason}`. A status outside
  2xx is a successful answer: the caller decides what a status means. `opts`
  carries `:connect_timeout`, `:timeout`, `:autoredirect` and `:max_bytes`; a
  body over `:max_bytes` is refused as `:body_too_large`, and the cap is also
  handed to `:httpc` as `max_body_size`, so an answer that is too large is not
  read into memory first. With no `:max_bytes` the body is not capped.
  """

  @connect_timeout 5_000
  @timeout 5_000

  @type method :: :get | :post
  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, non_neg_integer(), headers(), binary()} | {:error, term()}

  @doc """
  Sends one request to `uri` and answers the raw response.

  `headers` is a list of `{name, value}` strings; a missing `content-type` on a
  POST defaults to `application/json`.
  """
  @spec request(URI.t(), method(), headers(), iodata() | nil, keyword()) :: response()
  def request(%URI{} = uri, method, headers, body, opts \\ []) do
    request = request_tuple(uri, method, headers, body)

    # max_body_size is a request option, the fourth argument to :httpc, not an
    # HTTP option in the third: passed there it is silently ignored, and the
    # transport reads a response of any size into memory before the post-hoc
    # check below refuses it.
    case :httpc.request(method, request, httpc_options(opts), request_options(opts)) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        body = IO.iodata_to_binary(response_body)

        cap(status, normalize_headers(response_headers), body, Keyword.get(opts, :max_bytes))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_tuple(uri, :get, headers, _body) do
    {URI.to_string(uri), charlist_headers(headers)}
  end

  defp request_tuple(uri, :post, headers, body) do
    # The content-type is a header like any other to :httpc's tuple form, which
    # takes it as the third element of a POST. It is pulled out here rather
    # than added by the caller so one header list works for both verbs.
    {content_type, headers} = split_content_type(headers)
    {URI.to_string(uri), charlist_headers(headers), to_charlist(content_type), body}
  end

  defp cap(status, headers, body, nil), do: {:ok, status, headers, body}

  defp cap(status, headers, body, max_bytes) do
    if byte_size(body) > max_bytes,
      do: {:error, :body_too_large},
      else: {:ok, status, headers, body}
  end

  defp request_options(opts) do
    case Keyword.get(opts, :max_bytes) do
      nil -> []
      max_bytes -> [max_body_size: max_bytes]
    end
  end

  defp httpc_options(opts) do
    [
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout),
      timeout: Keyword.get(opts, :timeout, @timeout),
      ssl: ssl_options(),
      autoredirect: Keyword.get(opts, :autoredirect, false)
    ]
  end

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
