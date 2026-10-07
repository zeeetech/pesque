defmodule Pesque.HandleResolver do
  @moduledoc """
  Resolves a handle to a DID the way the ATProto handle spec says, and confirms
  the link is bidirectional before answering.

  DNS TXT at `_atproto.<handle>` first, `https://<handle>/.well-known/atproto-did`
  as the fallback. A resolution is only an answer once the DID's own document
  carries `at://<handle>`; that document is read through `Pesque.DidResolver`,
  so did:plc and did:web both resolve. Without the second check anyone could
  publish a TXT record pointing somebody else's handle at their own DID.

  The DNS lookup and the HTTPS fetch default to the real primitives and can be
  overridden through `:handle_resolver_dns` and `:handle_resolver_http`, so a
  test says what the network answered instead of arranging for it to answer.
  """

  alias Pesque.Did
  alias Pesque.DidResolver
  alias Pesque.OAuth.Fetch

  @timeout 5_000

  # The spec allows redirects "up to a reasonable number of redirect hops" and
  # does not name the number. Three is past anything a correct endpoint needs
  # and short enough that a loop cannot hold a caller.
  @max_redirects 3

  # A DID is well under 256 bytes and a DID document a few kilobytes. A larger
  # body is a host answering something other than what was asked for.
  @max_body_bytes 64 * 1024

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

  Answers `{:ok, did}` or `{:error, reason}`. The handle is a stranger's string
  and the network is somebody else's, so every failure is a reason rather than
  a raise.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(handle, opts \\ []) do
    dns_lookup = Keyword.get_lazy(opts, :dns_lookup, &default_dns_lookup/0)
    http_get = Keyword.get_lazy(opts, :http_get, &default_http_get/0)

    with {:ok, handle} <- normalize(handle),
         {:ok, did} <- resolve_did(handle, dns_lookup, http_get) do
      confirm_claim(handle, did)
    end
  end

  @doc """
  Whether `handle` resolves to `did` and `did`'s document claims `handle`.

  `:ok` or `{:error, reason}`. A handle that resolves to a different DID is
  `{:error, :handle_mismatch}`.
  """
  @spec verify(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify(handle, did, opts \\ []) do
    case resolve(handle, opts) do
      {:ok, ^did} -> :ok
      {:ok, _other} -> {:error, :handle_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `handle` resolves to `did`, without requiring `did`'s document to
  claim it yet.

  This is the check for a handle that is about to become a DID document's
  `alsoKnownAs`: the handle must already point at the account, and the document
  is what will catch up. `:ok` or `{:error, reason}`.
  """
  @spec resolves_to?(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def resolves_to?(handle, did, opts \\ []) do
    dns_lookup = Keyword.get_lazy(opts, :dns_lookup, &default_dns_lookup/0)
    http_get = Keyword.get_lazy(opts, :http_get, &default_http_get/0)

    with {:ok, handle} <- normalize(handle),
         {:ok, ^did} <- resolve_did(handle, dns_lookup, http_get) do
      :ok
    else
      {:ok, _other} -> {:error, :handle_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The stored spelling of a handle: trimmed, lowercased, and checked against the
  handle syntax and the disallowed TLDs. `{:ok, handle}` or `{:error, reason}`.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    cond do
      not Regex.match?(@handle_regex, normalized) -> {:error, :invalid_handle}
      tld(normalized) in @disallowed_tlds -> {:error, :disallowed_handle}
      true -> {:ok, normalized}
    end
  end

  def normalize(_handle), do: {:error, :invalid_handle}

  defp tld(handle), do: handle |> String.split(".") |> List.last()

  # DNS first. Any DNS failure other than an ambiguous record means the method
  # did not resolve the handle, so HTTPS is asked. A zone publishing two DIDs
  # is a failure outright, per the spec, rather than a coin flip between two
  # halves of a half-published name.
  defp resolve_did(handle, dns_lookup, http_get) do
    case dns_did(handle, dns_lookup) do
      {:ok, did} -> {:ok, did}
      {:error, :ambiguous_dns_record} -> {:error, :handle_unresolved}
      {:error, _unresolved} -> https_did(handle, http_get)
    end
  end

  # The _atproto. prefix adds 8 characters, so a handle long enough that the
  # prefixed name exceeds 253 bytes cannot be asked over DNS and falls through.
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

  # Records that do not start with did= are somebody else's data and are
  # ignored. Two different DIDs claiming the name is a failure, not a guess.
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
      {:error, _reason} -> {:error, :handle_unresolved}
    end
  end

  # A 2xx with a bare DID as the body. A redirect is followed up to the hop
  # budget, and the scheme is not downgraded: a Location pointing at http would
  # move the answer off TLS.
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

  # An injected primitive is the one thing called here whose code this module
  # does not control, so a raise is contained at the call rather than trusted.
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
        if Regex.match?(@did_regex, did), do: {:ok, did}, else: {:error, :malformed_did}

      _empty ->
        {:error, :empty_body}
    end
  end

  defp parse_did(_body), do: {:error, :malformed_body}

  # The second half of the spec: the DID's own document has to name the handle,
  # or the two are not linked. Read through DidResolver, so did:plc and did:web
  # resolve the same way.
  defp confirm_claim(handle, did) do
    with {:ok, document} <- DidResolver.resolve(did),
         true <- Did.claims_handle?(document, did, handle) do
      {:ok, did}
    else
      _unclaimed -> {:error, :handle_not_claimed}
    end
  end

  defp default_dns_lookup, do: Application.get_env(:pesque, :handle_resolver_dns, &dns_lookup/1)
  defp default_http_get, do: Application.get_env(:pesque, :handle_resolver_http, &http_get/1)

  @doc """
  The production TXT lookup: `{:ok, records}` or `{:error, reason}`.

  `:inet_res.resolve/5` is used rather than `lookup/5` because only the former
  tells NXDOMAIN apart from an empty answer. The timeout bounds it.
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

  # Only TXT answers are read. A record of another shape is an error rather
  # than a nil: a nil is indistinguishable from a name that published nothing.
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

  The transport is `Pesque.OAuth.Fetch.get/2`, so the scheme and address checks
  are the same ones every outbound request makes: a private or loopback answer
  is refused before the connection, TLS is verified, the timeout is bounded,
  redirects are not followed (the resolver counts the hops itself), and the
  body is capped.
  """
  def http_get(url) do
    with {:ok, uri} <- URI.new(url) do
      Fetch.get(uri, @max_body_bytes)
    else
      _ -> {:error, :invalid_url}
    end
  end
end
