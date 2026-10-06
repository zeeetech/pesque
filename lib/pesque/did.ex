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

  @doc "The username a path DID carries, or {:error, :invalid_did} when the DID is not a path DID of this mode."
  def username_from_did(:path_multi, did) do
    case did_parts(did) do
      {_host, ["user", username]} -> {:ok, username}
      _ -> {:error, :invalid_did}
    end
  end

  def username_from_did(:conformant_single, _did), do: {:error, :invalid_did}

  @doc "The path a DID document is served at, per the did:web resolution rules."
  def path_for_did(did) do
    case did_parts(did) do
      {_host, []} -> "/.well-known/did.json"
      {:error, _reason} -> {:error, :invalid_did}
      {_host, path} -> "/" <> Enum.join(path, "/") <> "/did.json"
    end
  end

  @doc "The ATProto PDS endpoint for a hostname."
  def service_endpoint(hostname), do: "https://" <> hostname

  @doc """
  The DID document for an account.

  `identity` carries the username (nil for the server itself), the hostname,
  the port, the handle domain, and the multibase public key.
  """
  def did_document(mode, %{
        username: username,
        hostname: hostname,
        port: port,
        handle_domain: handle_domain,
        pub_multibase: pub_multibase
      }) do
    did = did_for_username(mode, did_host(hostname, port), username)
    handle = handle_for_username(mode, handle_domain, username)

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
          "serviceEndpoint" => service_endpoint(hostname)
        }
      ]
    }
  end

  @doc """
  Whether a DID document claims `handle` for `did`.

  The other half of handle resolution: the handle resolved to a DID, and this
  is the DID document saying the same thing back. Without it a TXT record
  pointing somebody else's handle at your DID would pass, and every handle
  would be forgeable.

  The document's own `id` is checked against the DID that was expected rather
  than trusted, because a document served for one DID could name another, and
  the claim is only a claim about a DID.

  The first syntactically valid `at://` entry is the claimed handle, per the
  DID spec, so a later matching entry does not make an earlier non-matching
  one acceptable. Comparison is on the normalized handle, since handles are
  case-insensitive and only the lowercase form is meant to be stored.

  Pure, like the rest of this module: it reads the document it is given and
  consults nothing else, so it is the same question whether the document came
  off the network or out of a fixture.
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

  @doc """
  Resolves a local handle or DID to the canonical DID of that account.

  Answers one question: is this identifier an account of THIS server, and what
  is its canonical DID. That is the question the write boundary asks, so the
  caller compares two resolved DIDs, which is a plain equality.

  Whether a handle's domain is this server's DID host is configuration, not
  something either string carries, so the config is an argument.

  Deliberately consults no database. A resolver that cannot see the users
  table cannot be talked into accepting a remote account; whether the account
  exists is the caller's question, not this function's.

  Answers {:error, :not_local} for a DID of another host, a handle under a
  domain this server does not serve, and any path that is not exactly
  user/<username>.
  """
  def to_local_did(config, identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    case identifier |> String.downcase() |> String.split(":", parts: 3) do
      ["did", "web", rest] -> did_to_local_did(config, rest)
      _ -> handle_to_local_did(config, identifier)
    end
  end

  def to_local_did(_config, _identifier), do: {:error, :invalid_identifier}

  # The host and path arrive lowercased, so the host is compared folded
  # against did_host/2, which percent-encodes a port in uppercase hex.
  defp did_to_local_did(config, rest) do
    {did_host, path} = split_host_path(rest)

    with true <- did_host == String.downcase(host(config)),
         {:ok, username} <- username_in_did(config.mode, path) do
      {:ok, did_for_username(config.mode, host(config), username)}
    else
      _ -> {:error, :not_local}
    end
  end

  defp split_host_path(rest) do
    case String.split(rest, ":", parts: 2) do
      [host] -> {host, []}
      [host, path] -> {host, String.split(path, ":")}
    end
  end

  # nil is the server itself, the account a bare host DID names. It mirrors
  # bare_handle_did/1: under conformant_single both the bare DID and the bare
  # handle resolve to the single account, and under path_multi neither does,
  # because no account claims the bare domain.
  defp username_in_did(:conformant_single, []), do: {:ok, nil}
  defp username_in_did(:conformant_single, _path), do: {:error, :not_local}

  defp username_in_did(:path_multi, ["user", username]) do
    case normalize_username(username) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> {:error, :not_local}
    end
  end

  defp username_in_did(_mode, _path), do: {:error, :not_local}

  # The bare handle domain is the server's own handle in conformant_single,
  # where there is a single account and writes are addressed to it. Under
  # path_multi no account claims the bare domain, so it names nothing.
  defp handle_to_local_did(config, handle) do
    handle = String.downcase(handle)

    if handle == String.downcase(config.handle_domain) do
      bare_handle_did(config)
    else
      labeled_handle_did(config, handle)
    end
  end

  defp bare_handle_did(%{mode: :conformant_single} = config) do
    {:ok, did_for_username(:conformant_single, host(config), nil)}
  end

  defp bare_handle_did(_config), do: {:error, :not_local}

  # Only path_multi has accounts named by a label, so only there does a label
  # carry meaning. Under conformant_single the single account's handle is the
  # bare domain, and accepting a label here would widen what the write guard
  # takes without any account behind it.
  defp labeled_handle_did(%{mode: :path_multi} = config, handle) do
    with [username, domain] <- String.split(handle, ".", parts: 2),
         {:ok, username} <- normalize_username(username),
         true <- domain == String.downcase(config.handle_domain) do
      {:ok, did_for_username(:path_multi, host(config), username)}
    else
      _ -> {:error, :not_local}
    end
  end

  defp labeled_handle_did(_config, _handle), do: {:error, :not_local}

  defp host(config), do: did_host(config.hostname, config.port)

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
