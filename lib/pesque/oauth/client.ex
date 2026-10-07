defmodule Pesque.OAuth.Client do
  @moduledoc """
  The client metadata document: fetched from the `client_id` URL and validated.

  The atproto profile has no dynamic client registration. A client publishes a
  JSON document at a URL, that URL *is* the client_id, and everything the
  authorization server needs to know about the client is in it. So this module
  is the registry, and there is no table of registered clients.

  Checked, and why each check is here:

    * `client_id` in the document equals the URL it was fetched from, so a
      client cannot serve one document and be addressed by another.
    * `redirect_uris` is present and contains the redirect_uri the request
      names. This is what stops the authorization server from being used as an
      open redirector into somebody else's app.
    * `dpop_bound_access_tokens` is true. DPoP is mandatory in this profile, and
      a client declaring otherwise is asking for a bearer token it will then
      present without a proof.
    * `token_endpoint_auth_method` is `none` or `private_key_jwt`. Absent means
      public, which is every browser and mobile client in this profile. There
      is no client_secret anywhere in the atproto profile.

  Fetching is the SSRF risk the spec's security section is about: the URL comes
  from a stranger. So https only (the localhost development exception is served
  from a synthesized document and never fetched), TLS verified, no redirects,
  a timeout, a response size cap, and the resolved addresses refused when they
  are private. See Pesque.OAuth.Fetch for the shape of that check.
  """

  alias Pesque.OAuth.Fetch

  @max_redirect_uris 64
  @max_metadata_bytes 65_536

  @doc """
  Resolves a client_id into validated metadata.

  The localhost development exception lives here: a client_id of exactly
  `http://localhost` with an empty path needs no published document, because a
  developer running both halves locally has nowhere to publish one. Its
  redirect_uris come from the query string, its scopes default to `atproto`,
  and it is a public client.
  """
  def resolve(client_id) when is_binary(client_id) do
    case parse(client_id) do
      {:ok, {:localhost, uri}} -> {:ok, localhost_client(uri)}
      {:ok, {:remote, uri}} -> fetch_metadata(uri)
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(_client_id), do: {:error, :invalid_client_id}

  @doc "Whether `redirect_uri` is one the client's metadata declares."
  def redirect_uri_allowed?(metadata, redirect_uri) when is_binary(redirect_uri) do
    Enum.any?(redirect_uris(metadata), fn declared ->
      declared == redirect_uri or same_path_different_port?(declared, redirect_uri)
    end)
  end

  def redirect_uri_allowed?(_metadata, _redirect_uri), do: false

  @doc "The scopes the client's own metadata declares, as a list."
  def declared_scopes(metadata) when is_map(metadata) do
    metadata |> Map.get("scope", "") |> String.split(" ", trim: true)
  end

  def declared_scopes(_metadata), do: []

  @doc "Whether the client's metadata declares every scope in a string."
  def scopes_declared?(metadata, scope) when is_binary(scope) do
    declared = declared_scopes(metadata)
    Enum.all?(String.split(scope, " ", trim: true), &(&1 in declared))
  end

  def scopes_declared?(_metadata, _scope), do: false

  @doc "Whether the client authenticates itself, rather than being public."
  def confidential?(metadata), do: auth_method(metadata) == "private_key_jwt"

  @doc "The client's `token_endpoint_auth_method`, defaulting to public."
  def auth_method(%{"token_endpoint_auth_method" => method}) when is_binary(method), do: method
  def auth_method(_metadata), do: "none"

  @doc "The client's public keys, from `jwks` or fetched from `jwks_uri`."
  def jwks(%{"jwks" => %{"keys" => [_ | _] = keys}}), do: {:ok, keys}
  def jwks(%{"jwks" => %{"keys" => keys}}) when is_list(keys), do: {:error, :no_client_keys}

  def jwks(%{"jwks_uri" => uri}) when is_binary(uri) do
    case parse(uri) do
      {:ok, {:remote, parsed}} -> Fetch.json(parsed, @max_metadata_bytes)
      _other -> {:error, :no_client_keys}
    end
  end

  def jwks(_metadata), do: {:error, :no_client_keys}

  # The localhost development client is the one client_id that is not https,
  # and it is recognized before the https rule so it can be answered from a
  # synthesized document instead of a fetch.
  defp parse(client_id) do
    case URI.new(client_id) do
      {:ok, %URI{userinfo: nil, fragment: nil, host: host} = uri}
      when is_binary(host) and host != "" ->
        classify(uri)

      _other ->
        {:error, :invalid_client_id}
    end
  end

  defp classify(%URI{scheme: "https", port: port} = uri) when port in [nil, 443],
    do: {:ok, {:remote, uri}}

  defp classify(%URI{scheme: "http", port: port} = uri) when port in [nil, 80] do
    if localhost?(uri), do: {:ok, {:localhost, uri}}, else: {:error, :invalid_client_id}
  end

  defp classify(_uri), do: {:error, :invalid_client_id}

  defp localhost?(%URI{host: "localhost"} = uri) do
    uri.path in [nil, "", "/"]
  end

  defp localhost?(_uri), do: false

  defp fetch_metadata(uri) do
    with {:ok, document} <- Fetch.json(uri, @max_metadata_bytes),
         {:ok, metadata} <- validate(document, uri) do
      {:ok, metadata}
    end
  end

  defp validate(document, uri) do
    cond do
      Map.get(document, "client_id") != without_query(uri) ->
        {:error, :client_id_mismatch}

      not includes_code?(document) ->
        {:error, :invalid_client_metadata}

      redirect_uris(document) == [] ->
        {:error, :invalid_client_metadata}

      Map.get(document, "dpop_bound_access_tokens") != true ->
        {:error, :dpop_not_bound}

      auth_method(document) not in ["none", "private_key_jwt"] ->
        {:error, :unsupported_auth_method}

      true ->
        {:ok, document}
    end
  end

  # The client_id inside the document is the URL it was fetched from, and for a
  # localhost client that URL carries the redirect_uri and scope parameters, so
  # the comparison is against the URL without them.
  defp without_query(%URI{query: nil} = uri), do: URI.to_string(uri)
  defp without_query(%URI{} = uri), do: uri |> Map.put(:query, nil) |> URI.to_string()

  defp includes_code?(document) do
    "code" in as_list(Map.get(document, "response_types"))
  end

  defp redirect_uris(%{"redirect_uris" => uris}) when is_list(uris) do
    uris |> Enum.filter(&is_binary/1) |> Enum.take(@max_redirect_uris)
  end

  defp redirect_uris(_document), do: []

  # The localhost exception declares its redirect URIs by query parameter, and
  # the port is not part of the match: a native app picks one at run time.
  # Everything else has to match exactly, because a native app's custom scheme
  # is not something to loosen.
  defp same_path_different_port?(declared, requested) do
    with {:ok, a} <- URI.new(declared),
         {:ok, b} <- URI.new(requested),
         true <- a.scheme == "http" and b.scheme == "http",
         true <- a.host == b.host,
         true <- a.path == b.path,
         true <- a.query == b.query do
      loopback?(a.host)
    else
      _ -> false
    end
  end

  defp loopback?("127.0.0.1"), do: true
  defp loopback?("[::1]"), do: true
  defp loopback?("::1"), do: true
  defp loopback?(_host), do: false

  defp localhost_client(uri) do
    params =
      case uri.query do
        nil -> %{}
        query -> query |> Plug.Conn.Query.decode() |> Map.new()
      end

    %{}
    |> Map.put("client_id", without_query(uri))
    |> Map.put("client_name", "Development client")
    |> Map.put("response_types", ["code"])
    |> Map.put("grant_types", ["authorization_code", "refresh_token"])
    |> Map.put("redirect_uris", localhost_redirect_uris(params))
    |> Map.put("scope", Map.get(params, "scope", "atproto"))
    |> Map.put("token_endpoint_auth_method", "none")
    |> Map.put("application_type", "native")
    |> Map.put("dpop_bound_access_tokens", true)
  end

  defp localhost_redirect_uris(params) do
    case Map.get(params, "redirect_uri") do
      nil -> ["http://127.0.0.1/", "http://[::1]/"]
      single when is_binary(single) -> [single]
      many when is_list(many) -> Enum.filter(many, &is_binary/1)
      _other -> ["http://127.0.0.1/", "http://[::1]/"]
    end
  end

  defp as_list(nil), do: []
  defp as_list(list) when is_list(list), do: list
  defp as_list(_other), do: []
end
