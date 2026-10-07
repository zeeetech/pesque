defmodule Pesque.Did do
  @moduledoc """
  DID and handle derivation, and DID document construction.

  Pure: every function takes the mode, hostname, handle domain, port, and
  public key it needs. Nothing here reads configuration, the database, or a
  process, so both modes are testable without a running server.

  Known limitation: a real hostname on a non-443 port with nothing
  terminating TLS in front publishes a portless DID that does not resolve.
  The public topology is not knowable from inside the server, so an operator
  who needs it has to front the port themselves.
  """

  @username_regex ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

  # The atproto limit on a DID, which bounds what a resolution is allowed to
  # build a URL out of.
  @did_max_length 2048

  @doc """
  The did:web authority for a hostname, with the port percent-encoded.

  did:web requires the percent encoding, and the encoding is applied only to
  loopback and private hosts: the listening port is not the public one when
  a proxy terminates TLS, so putting it on a public hostname would publish
  an internal port and stop the DID from resolving.
  """
  def did_host(hostname, port) do
    if port in [nil, 443] or not local?(hostname) do
      hostname
    else
      hostname <> URI.encode_www_form(":" <> to_string(port))
    end
  end

  @doc "The DID for a username, or for the server itself when the username is nil."
  def did_for_username(:conformant_single, host, _username), do: "did:web:" <> host
  def did_for_username(:path_multi, host, nil), do: "did:web:" <> host

  def did_for_username(:path_multi, host, username) do
    "did:web:" <> host <> ":user:" <> normalize_username!(username)
  end

  @doc "The handle for a username, or the bare handle domain when the username is nil."
  def handle_for_username(:conformant_single, handle_domain, _username), do: handle_domain
  def handle_for_username(:path_multi, handle_domain, nil), do: handle_domain

  def handle_for_username(:path_multi, handle_domain, username) do
    normalize_username!(username) <> "." <> handle_domain
  end

  @doc "The path a DID document is served at, per the did:web resolution rules."
  def path_for_did(did) do
    case did_parts(did) do
      {_host, []} -> "/.well-known/did.json"
      {:error, _reason} -> {:error, :invalid_did}
      {_host, path} -> "/" <> Enum.join(path, "/") <> "/did.json"
    end
  end

  @doc """
  The HTTPS URI a did:web resolves to, per the did:web resolution rules.

  The first method-specific segment is the authority, with `%3A` decoded to a
  port separator; the remaining segments are the path, and an empty path is the
  `.well-known` document. Answers `{:ok, %URI{}}` or `{:error, :invalid_did}`.
  The URI is untrusted: the caller still applies its own scheme and address
  checks before fetching it.
  """
  def web_uri(did) when is_binary(did) do
    with true <- byte_size(did) <= @did_max_length,
         ["did", "web", rest] <- String.split(did, ":", parts: 3),
         [host | _path] <- String.split(rest, ":"),
         path when is_binary(path) <- path_for_did(did) do
      case URI.new("https://" <> decode_port(host) <> path) do
        {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri}
        when is_binary(host) and host != "" ->
          {:ok, uri}

        _other ->
          {:error, :invalid_did}
      end
    else
      _other -> {:error, :invalid_did}
    end
  end

  def web_uri(_did), do: {:error, :invalid_did}

  defp decode_port(host), do: String.replace(host, ~r/%3[aA]/, ":")

  @doc """
  The did:key identifier for a compressed secp256k1 public key.

  Same multikey bytes as a `publicKeyMultibase` (multicodec 0xE7, compressed,
  base58btc, `z` prefix), with the `did:key:` scheme in front. This is the
  encoding PLC operations use for rotation and signing keys.
  """
  def key_did(compressed_pub) do
    "did:key:" <> Pesque.Secp256k1.public_key_multibase(compressed_pub)
  end

  @doc """
  The DID document for an account.

  `identity` carries the username (nil for the server itself), the hostname,
  the port, the handle domain, and the multibase public key.
  """
  def did_document(
        mode,
        %{
          username: username,
          hostname: hostname,
          port: port,
          handle_domain: handle_domain,
          pub_multibase: pub_multibase
        } = attrs
      ) do
    did = did_for_username(mode, did_host(hostname, port), username)
    handle = handle_for_username(mode, handle_domain, username)
    endpoint = Map.get(attrs, :endpoint, "https://" <> hostname)

    document(did, handle, pub_multibase, endpoint)
  end

  @doc """
  The DID document for a did:plc account, keyed by the stored DID.

  A did:plc account's document is published by the PLC directory, not by this
  server, but describeRepo still has to render one and the DID is the stored
  string rather than anything re-derived. `endpoint` is this server's PDS
  endpoint, the same one the genesis operation published.
  """
  def plc_document(%{did: did, handle: handle, pub_multibase: pub_multibase, endpoint: endpoint}) do
    document(did, handle, pub_multibase, endpoint)
  end

  defp document(did, handle, pub_multibase, endpoint) do
    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/multikey/v1"
      ],
      "id" => did,
      "alsoKnownAs" => ["at://" <> handle],
      "verificationMethod" => [
        %{
          "id" => did <> "#atproto",
          "type" => "Multikey",
          "controller" => did,
          "publicKeyMultibase" => pub_multibase
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => endpoint
        }
      ]
    }
  end

  @doc """
  Whether a DID document claims `handle` for `did`.

  The document's own `id` is checked against the expected DID rather than
  trusted, and `alsoKnownAs` has to carry `at://<handle>`. Without it a TXT
  record pointing somebody else's handle at a DID would pass. Pure: it reads
  the document it is given and consults nothing else.
  """
  def claims_handle?(document, did, handle)
      when is_map(document) and is_binary(did) and is_binary(handle) do
    document["id"] == did and claimed_handle(document["alsoKnownAs"]) == normalize!(handle)
  end

  def claims_handle?(_document, _did, _handle), do: false

  defp claimed_handle(entries) when is_list(entries) do
    Enum.find_value(entries, fn
      "at://" <> handle when handle != "" -> normalize!(handle)
      _not_a_handle -> nil
    end)
  end

  defp claimed_handle(_entries), do: nil

  @doc """
  Lowercases a username and checks it against the handle label rules, returning
  {:ok, username} or {:error, reason}.
  """
  def normalize_username(username) when is_binary(username) do
    case username |> String.trim() |> String.trim_leading("@") |> String.downcase() do
      "" ->
        {:error, :empty}

      normalized ->
        if Regex.match?(@username_regex, normalized),
          do: {:ok, normalized},
          else: {:error, :invalid}
    end
  end

  def normalize_username(_username), do: {:error, :not_a_string}

  defp did_parts(did) do
    case String.split(did, ":") do
      ["did", "web", host | path] -> {host, path}
      _ -> {:error, :not_did_web}
    end
  end

  # A handle is compared, not validated: the caller is a resolver that has
  # already settled the syntax, and this is here so the two sides of the
  # comparison agree on spelling whatever the document published.
  defp normalize!(handle),
    do: handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

  defp normalize_username!(username) do
    case normalize_username(username) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError, "invalid username: #{inspect(reason)}"
    end
  end

  defp local?("localhost"), do: true

  defp local?(hostname) do
    String.ends_with?(hostname, ".localhost") or
      String.starts_with?(hostname, "127.") or
      String.starts_with?(hostname, "10.") or
      String.starts_with?(hostname, "192.168.") or
      String.starts_with?(hostname, "169.254.") or
      private_172?(hostname) or
      local_v6?(hostname)
  end

  defp private_172?("172." <> rest) do
    case rest |> String.split(".") |> hd() |> Integer.parse() do
      {octet, _} when octet in 16..31 -> true
      _ -> false
    end
  end

  defp private_172?(_hostname), do: false

  defp local_v6?("::1"), do: true
  defp local_v6?(<<octet, _rest::binary>>) when octet in [0xFC, 0xFD], do: true
  defp local_v6?(_hostname), do: false
end
