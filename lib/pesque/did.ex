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
    "did:web:" <> host <> ":user:" <> normalized!(username)
  end

  @doc "The handle for a username, or the bare handle domain when the username is nil."
  def handle_for_username(:conformant_single, handle_domain, _username), do: handle_domain
  def handle_for_username(:path_multi, handle_domain, nil), do: handle_domain

  def handle_for_username(:path_multi, handle_domain, username) do
    normalized!(username) <> "." <> handle_domain
  end

  @doc "The username a path DID carries, or :error when the DID is not a path DID of this mode."
  def username_from_did(:path_multi, did) do
    case did_parts(did) do
      {_host, ["user", username]} -> {:ok, username}
      _ -> :error
    end
  end

  def username_from_did(:conformant_single, _did), do: :error

  @doc "The path a DID document is served at, per the did:web resolution rules."
  def path_for_did(did) do
    case did_parts(did) do
      {_host, []} -> "/.well-known/did.json"
      {:error, _} -> :error
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
  True when two repo identifiers name the same account.

  A path DID mirrors the handle it was derived from, so a handle and its DID
  compare equal here without a database lookup.
  """
  def same_account?(left, right) when is_binary(left) and is_binary(right) do
    left = String.downcase(String.trim(left))
    right = String.downcase(String.trim(right))

    left == right or mirrors?(left, right) or mirrors?(right, left)
  end

  def same_account?(_left, _right), do: false

  defp mirrors?(did, handle) do
    case String.split(handle, ".", parts: 2) do
      [username, domain] -> did == "did:web:" <> domain <> ":user:" <> username
      _ -> false
    end
  end

  defp did_parts(did) do
    case String.split(did, ":") do
      ["did", "web", host | path] -> {host, path}
      _ -> {:error, :not_did_web}
    end
  end

  defp normalized!(username) do
    case normalize_username(username) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid username: #{inspect(reason)}"
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
