defmodule Pesque.HandleResolver do
  @moduledoc """
  Resolves a handle to a DID the way the ATProto handle spec says, and confirms
  the link is bidirectional before answering.

  Two methods, in the order the spec asks for. The DNS TXT record at
  `_atproto.<handle>` is preferred; `https://<handle>/.well-known/atproto-did`
  is the fallback for domains that cannot publish one. A handle that resolves
  through neither is not resolved.

  A resolution is only an answer once the DID document says the same thing.
  The DID document's `alsoKnownAs` has to carry `at://<handle>`, otherwise
  anyone could publish a TXT record pointing somebody else's handle at their
  own DID and pass it off as an alias. That check is why this module fetches a
  second document rather than trusting the first answer.

  ## The DNS record is the operator's job

  Nothing here can publish `_atproto.<handle>`. Creating it means editing the
  zone at whoever holds the domain, through whatever interface that registrar
  offers, and re-reading it back from the public internet. An operator who
  wants DNS-based resolution publishes:

      _atproto.alice.example.com.  IN TXT  "did=did:web:pds.example.com:user:alice"

  Until that record exists, the HTTPS method is what carries the handle. A
  handle with neither a TXT record nor a well-known endpoint does not resolve,
  and no code in this server can change that.

  ## Injected primitives

  Both network primitives are arguments rather than calls to a module, so a
  test can say what the network answered instead of arranging for it to answer.
  They are two plain functions with contracts, not a behaviour: there is one
  implementation of each here and one caller shape, and a behaviour module
  would add a module and a dispatch indirection without adding a second
  implementation to choose between. Mox exists for the case where a test has to
  assert on a fake; these tests assert on the resolver's answers, and the
  fakes they need are two closures.

  `dns_lookup` takes a domain name and answers `{:ok, records}` with the TXT
  values, or `{:error, reason}`. `http_get` takes a URL and answers
  `{:ok, status, headers, body}` or `{:error, reason}`. Both are total: they
  answer a reason rather than raising, and the timeouts below bound them.
  """

  alias Pesque.Did

  @connect_timeout 5_000
  @timeout 5_000
  @profile :httpc_pesque_handle_resolver

  # The spec allows redirects "up to a reasonable number of redirect hops" and
  # does not say what the number is. Three is past anything a correctly
  # configured atproto endpoint needs and short enough that a redirect loop
  # cannot hold a caller.
  @max_redirects 3

  # A DID is well under 256 bytes and a DID document a few kilobytes. A larger
  # body is a host answering something other than what was asked for, and
  # reading it to find that out is what the cap prevents.
  @max_body_bytes 64 * 1024

  @plc_directory "https://plc.directory"

  @handle_regex ~r/^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/
  @did_regex ~r/^did:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]$/

  @disallowed_tlds ~w(alt arpa example internal invalid local localhost onion)

  @typedoc "The TXT values for a domain name, or why the lookup failed."
  @type dns_lookup :: (String.t() -> {:ok, [String.t() | nil]} | {:error, term()})

  @typedoc "One HTTPS response: status, headers and body."
  @type response ::
          {:ok, non_neg_integer(), [{char(), char()}], binary()} | {:error, term()}

  @type http_get :: (String.t() -> response())

  @doc """
  Resolves `handle` to the DID it is bidirectionally linked to.

  Answers `{:ok, did}` or `{:error, reason}`. Never raises: the handle is a
  string a stranger supplied and the network is somebody else's, so every
  failure is reachable from a crafted input.

  `dns_lookup` and `http_get` default to the real primitives, `dns_lookup/1`
  and `http_get/1`. A caller with its own passes them, which is how the tests
  run without a network.
  """
  @spec resolve(String.t(), dns_lookup, http_get) :: {:ok, String.t()} | {:error, term()}
  def resolve(handle, dns_lookup \\ &dns_lookup/1, http_get \\ &http_get/1) do
    with {:ok, handle} <- normalize_handle(handle),
         {:ok, did} <- resolve_did(handle, dns_lookup, http_get) do
      verify_bidirectional(handle, did, http_get)
    end
  end

  # Only a lowercased, syntactically valid handle reaches the network. The
  # disallowed TLDs are refused here rather than resolved: the spec says they
  # must fail resolution, and .local and .onion cannot be resolved from the
  # public internet anyway.
  defp normalize_handle(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    cond do
      not Regex.match?(@handle_regex, normalized) -> {:error, :invalid_handle}
      tld(normalized) in @disallowed_tlds -> {:error, :disallowed_handle}
      true -> {:ok, normalized}
    end
  end

  defp normalize_handle(_handle), do: {:error, :invalid_handle}

  defp tld(handle), do: handle |> String.split(".") |> List.last()

  # DNS first, and its failure is not the end of resolution: NXDOMAIN, an
  # empty answer and a malformed record all mean the same thing here, which is
  # that this method did not resolve the handle and the other one gets asked.
  # The spec's guidance for the two methods disagreeing is that DNS wins, so a
  # DNS answer is used as it stands and never second-guessed against HTTPS.

  # A zone publishing two different DIDs is a failure rather than a fall
  # through: the spec says resolution fails and can be retried after a delay,
  # and asking HTTPS instead would answer from whichever half of a
  # half-published name happens to be serving. Every other DNS failure means
  # the method simply did not resolve the handle, so HTTPS gets asked.
  defp resolve_did(handle, dns_lookup, http_get) do
    case dns_did(handle, dns_lookup) do
      {:ok, did} -> {:ok, did}
      {:error, :ambiguous_dns_record} = error -> error
      {:error, _unresolved} -> https_did(handle, http_get)
    end
  end

  # The _atproto. prefix adds 8 characters to the query name, so a handle long
  # enough that the prefixed name would exceed 253 bytes cannot be asked over
  # DNS at all. The spec says so and points at HTTPS for those handles.
  defp dns_did(handle, dns_lookup) do
    name = "_atproto." <> handle

    if byte_size(name) > 253 do
      {:error, :handle_too_long_for_dns}
    else
      with {:ok, records} <- safely(dns_lookup, name),
           {:ok, did} <- single_did(records) do
        {:ok, did}
      else
        {:error, :ambiguous_dns_record} = error -> error
        _unresolvable -> {:error, :no_dns_record}
      end
    end
  end

  # Records that do not start with did= are somebody else's data (SPF, a
  # verification token) and are ignored, per the spec. What must not happen is
  # two different DIDs both claiming the handle: picking one would be a coin
  # flip on a zone that is mid-migration or being attacked, so a name with
  # more than one answer is a failure rather than a guess.

  # Rejected before the distinctness check, not after: a record that is not a
  # did= value is not an answer at all, so three of them are zero answers and
  # one of them plus a valid record is one answer.
  defp single_did(records) do
    case records |> Enum.map(&did_value/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [did] -> {:ok, did}
      [] -> {:error, :no_did_record}
      _multiple -> {:error, :ambiguous_dns_record}
    end
  end

  defp did_value("did=" <> did) do
    if Regex.match?(@did_regex, did), do: did, else: nil
  end

  defp did_value(_record), do: nil

  defp https_did(handle, http_get) do
    url = "https://" <> handle <> "/.well-known/atproto-did"

    case well_known_did(url, http_get, @max_redirects) do
      {:ok, did} -> {:ok, did}
      {:error, reason} -> {:error, {:https_failed, reason}}
    end
  end

  # A 2xx with a bare DID as the body. Content-Type is not checked: the spec
  # says it need not be verified strictly, and requiring it would refuse
  # servers that are otherwise correct. Whitespace is stripped before parsing
  # because the spec tells clients to tolerate a trailing newline.
  #
  # A redirect is followed, up to the hop budget. The scheme is not downgraded:
  # a Location pointing at http would move the answer off TLS, and the spec
  # requires https for every real resolution.
  defp well_known_did(url, http_get, hops_left) do
    case safely(http_get, url) do
      {:ok, status, _headers, body} when status in 200..299 ->
        parse_did(body)

      {:ok, status, headers, _body} when status in 300..399 and hops_left > 0 ->
        case redirect_target(headers) do
          {:ok, next} -> well_known_did(next, http_get, hops_left - 1)
          :error -> {:error, {:bad_redirect, status}}
        end

      {:ok, status, _headers, _body} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  defp redirect_target(headers) do
    with {_name, location} <- header(headers, ~c"location"),
         %URI{scheme: "https", host: host} = uri when host not in [nil, ""] <- URI.parse(location) do
      {:ok, URI.to_string(uri)}
    else
      _ -> :error
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if to_string(key) |> String.downcase() == to_string(name), do: {key, to_string(value)}
    end)
  end

  # The guarantee is "never raises", and an injected primitive is the one thing
  # called here whose code this module does not control. Contained at the call
  # rather than in the primitive, because a caller-supplied function is the
  # only way an exception can get in.
  defp safely(primitive, argument) do
    primitive.(argument)
  rescue
    _raised -> {:error, :resolver_failed}
  catch
    _kind, _reason -> {:error, :resolver_failed}
  end

  defp parse_did(body) when is_binary(body) do
    case String.trim(body) do
      did when did != "" ->
        if Regex.match?(@did_regex, did),
          do: {:ok, did},
          else: {:error, :malformed_did}

      _empty ->
        {:error, :empty_body}
    end
  end

  defp parse_did(_body), do: {:error, :malformed_body}

  # The second half of the spec's requirement. The handle resolved to a DID,
  # and now that DID's own document has to name the handle, or the two are not
  # linked and the resolution is refused.
  defp verify_bidirectional(handle, did, http_get) do
    with {:ok, document} <- fetch_did_document(did, http_get),
         true <- Did.claims_handle?(document, did, handle) do
      {:ok, did}
    else
      _unclaimed -> {:error, :not_bidirectional}
    end
  end

  defp fetch_did_document(did, http_get) do
    with {:ok, url} <- document_url(did),
         {:ok, status, _headers, body} <- safely(http_get, url),
         true <- status in 200..299,
         {:ok, document} <- decode_document(body) do
      {:ok, document}
    else
      _unavailable -> {:error, :did_document_unavailable}
    end
  end

  defp document_url("did:plc:" <> _ = did), do: {:ok, @plc_directory <> "/" <> did}

  defp document_url("did:web:" <> rest = did),
    do: {:ok, "https://" <> did_web_host(rest) <> Did.path_for_did(did)}

  defp document_url(_did), do: {:error, :unsupported_did_method}

  # did:web percent-encodes the port so the whole authority is one DNS label.
  # An HTTP URL wants it back as a port, and a DID that encodes one only
  # resolves if the port is really listening, so it is restored rather than
  # left percent-encoded into a hostname nothing can serve.
  defp did_web_host(rest) do
    case String.split(rest, ":", parts: 2) do
      [host] -> URI.decode(host)
      [host, _path] -> host |> URI.decode() |> String.split("%3A", parts: 2) |> hd()
    end
  end

  defp decode_document(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _malformed -> {:error, :malformed_did_document}
    end
  end

  defp decode_document(_body), do: {:error, :malformed_did_document}

  @doc """
  The production TXT lookup: `{:ok, records}` or `{:error, reason}`.

  The records are the raw TXT values as strings. `:inet_res.resolve/5` is used
  rather than `lookup/5` because only the former tells NXDOMAIN apart from an
  empty answer, and the distinction is worth having when an operator is
  debugging why a handle does not resolve.
  """
  def dns_lookup(name) do
    with {:ok, {:dns_rec, _header, _query, answers, _authority, _additional}} <-
           :inet_res.resolve(String.to_charlist(name), :in, :txt, [], @timeout),
         {:ok, values} <- txt_values(answers) do
      {:ok, values}
    else
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :unexpected_dns_answer}
    end
  rescue
    _raised -> {:error, :resolver_failed}
  catch
    _kind, _reason -> {:error, :resolver_failed}
  end

  # Only TXT answers are read, and only from a record shaped the way this
  # expects. A record of some other shape is an error rather than a nil: a nil
  # here is indistinguishable from a name that published nothing, which is the
  # one answer that looks correct while being wrong, and #dns_rr{}'s arity is
  # easy to get wrong silently.
  defp txt_values(answers) do
    Enum.reduce_while(answers, {:ok, []}, fn
      {:dns_rr, _domain, :txt, _class, _cnt, _ttl, segments, _tm, _bm, _do}, {:ok, acc}
      when is_list(segments) ->
        value = segments |> Enum.map(&List.to_string/1) |> Enum.join()
        {:cont, {:ok, [value | acc]}}

      _other, _acc ->
        {:halt, {:error, :unexpected_dns_answer}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @doc """
  The production HTTPS fetch: `{:ok, status, headers, body}` or `{:error, reason}`.

  TLS is verified, the timeout is bounded, redirects are not followed (the
  resolver does that itself so it can count the hops and refuse a downgrade),
  and the body is capped. `:inets` and `:ssl` rather than a client library: it
  is OTP, and the request is one small GET.
  """
  def http_get(url) do
    profile = start_profile()

    case :httpc.request(
           :get,
           {url, [{~c"accept", ~c"text/plain, application/json"}]},
           [
             connect_timeout: @connect_timeout,
             timeout: @timeout,
             ssl: ssl_options(),
             autoredirect: false
           ],
           [body_format: :binary],
           profile
         ) do
      {:ok, {{_version, status, _reason}, headers, body}}
      when is_binary(body) and byte_size(body) <= @max_body_bytes ->
        {:ok, status, headers, body}

      {:ok, {{_version, _status, _reason}, _headers, body}}
      when is_binary(body) ->
        {:error, {:body_too_large, byte_size(body)}}

      {:ok, {_status_line, _headers, _body}} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _raised -> {:error, :fetch_failed}
  catch
    _kind, _reason -> {:error, :fetch_failed}
  end

  # A profile carries body_format, which is not a per-request option: passed in
  # the request options httpc logs "Invalid option" and hands back a charlist,
  # so a body that has to be measured arrives as a list and every byte_size/1
  # on it raises. The profile is started once and reused.
  defp start_profile do
    case :inets.start(:httpc, [{:profile, @profile}, {:body_format, :binary}]) do
      {:ok, _pid} -> @profile
      {:error, {:already_started, _pid}} -> @profile
      {:error, _reason} -> @profile
    end
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
