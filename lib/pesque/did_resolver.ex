defmodule Pesque.DidResolver do
  @moduledoc """
  Resolving an atproto DID to its DID document.

  did:plc is read from the PLC directory; did:web is fetched from the host the
  DID names. A did:web host is a stranger's URL, so the fetch is the hardened
  one from `Pesque.OAuth.Fetch`: https only, TLS verified, no redirects, a byte
  cap, and every resolved address refused when it is private. See that module
  for what the check does and does not close.

  A DID is untrusted input, so every branch here answers a tagged tuple and
  never raises. Every outbound request is bounded by the explicit connect and
  request timeout in `Pesque.OAuth.Fetch`, which both the directory client and
  the did:web fetch go through.

  The directory and the fetcher are configuration, the same way `Pesque.Plc`
  swaps its directory client, so a test never reaches the network.
  """

  alias Pesque.Did

  @max_bytes 1_048_576
  @did_max_length 2048

  # The atproto DID syntax: lowercase method, then a subset of ASCII that may
  # not end in a separator. Length is bounded separately.
  @did_regex ~r/\Adid:[a-z]+:[a-zA-Z0-9._:%-]*[a-zA-Z0-9._-]\z/

  @doc """
  Resolves `did` to its DID document.

  Answers `{:ok, document}` or `{:error, reason}`. Only did:plc and did:web are
  supported, so any other method is `{:error, :unsupported_did_method}` rather
  than an attempt to resolve something this server does not understand.
  """
  @spec resolve(String.t()) :: {:ok, map()} | {:error, term()}
  def resolve(did) when is_binary(did) do
    with :ok <- check_syntax(did) do
      case did do
        "did:plc:" <> _rest -> resolve_plc(did)
        "did:web:" <> _rest -> resolve_web(did)
        _other -> {:error, :unsupported_did_method}
      end
    end
  end

  def resolve(_did), do: {:error, :invalid_did}

  defp check_syntax(did) do
    if byte_size(did) <= @did_max_length and Regex.match?(@did_regex, did) do
      :ok
    else
      {:error, :invalid_did}
    end
  end

  defp resolve_plc(did) do
    with {:ok, document} <- call(fn -> directory().resolve(did) end) do
      normalize(document, did)
    end
  end

  defp resolve_web(did) do
    with {:ok, uri} <- Did.web_uri(did),
         {:ok, document} <- call(fn -> fetcher().json(uri, @max_bytes) end) do
      normalize(document, did)
    end
  end

  # The document's own id has to be the DID that was resolved. The directory
  # always answers the document for the DID in the path; a did:web host is free
  # to serve anything, and this is what stops one account's document from being
  # accepted under another account's DID.
  defp normalize(%{"id" => id} = document, did) when is_binary(id) do
    if id == did, do: {:ok, document}, else: {:error, :did_mismatch}
  end

  defp normalize(_document, _did), do: {:error, :invalid_did_document}

  # A client is injectable, so one that raises is answered rather than allowed
  # to escape: the DID came from a stranger and a resolver that raises on one
  # is a denial of service.
  defp call(fun) do
    fun.()
  rescue
    _error -> {:error, :did_resolution_failed}
  catch
    _kind, _value -> {:error, :did_resolution_failed}
  end

  defp directory, do: Application.get_env(:pesque, :did_resolver_directory, Pesque.Plc.Directory)

  defp fetcher, do: Application.get_env(:pesque, :did_resolver_fetch, Pesque.OAuth.Fetch)
end
