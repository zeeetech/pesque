defmodule Pesque.Doctor do
  @moduledoc """
  A federation preflight: the checks that decide whether this server is
  reachable and resolvable from outside, which is what a PDS has to be to be
  useful. It automates the manual verify list in the installation guide.

  Every check answers `{status, title, detail}` with status `:ok`, `:warn` or
  `:fail`. The checks are read-only: none of them writes or changes anything.

  `checks/1` takes seams (`:http`, `:resolver`, `:resolves`) so the logic can be
  exercised without a network; the defaults are the real ones.
  """

  alias Pesque.HandleResolver
  alias Pesque.Identity

  @doc "Runs every check, cheapest and most local first."
  def checks(opts \\ []) do
    http = Keyword.get(opts, :http, &http_get/1)
    resolver = Keyword.get(opts, :resolver, &resolve/1)
    resolves = Keyword.get(opts, :resolves, &HandleResolver.resolves_to?/2)

    [
      config_check(),
      dns_check(resolver),
      describe_check(http),
      did_document_check(http),
      handle_check(resolves)
    ]
  end

  @doc """
  Runs the checks, prints one line each, and answers `:ok` or `:error`.

  This is the release-friendly entry:
  `bin/pesque eval 'Pesque.Release.boot!(); Pesque.Doctor.run()'` answers it
  without Mix, which a container image does not carry. `boot!` is required
  because a release `eval` does not start the application, so the server
  identity is not loaded until it does.
  """
  def run(opts \\ []) do
    results = checks(opts)

    IO.puts("Pesque federation preflight")
    IO.puts("")

    Enum.each(results, fn {status, title, detail} ->
      IO.puts("#{label(status)} #{title}: #{detail}")

      if next = hint(status, title) do
        IO.puts("       -> #{next}")
      end
    end)

    failed = Enum.count(results, &match?({:fail, _title, _detail}, &1))
    warned = Enum.count(results, &match?({:warn, _title, _detail}, &1))

    IO.puts("")

    if failed > 0 do
      IO.puts("#{failed} check(s) failed#{warnings(warned)}; the server is not reachable")
      IO.puts("from outside yet.")
      :error
    else
      IO.puts("All checks passed#{warnings(warned)}; the server is reachable and resolvable.")
      :ok
    end
  end

  defp warnings(0), do: ""
  defp warnings(n), do: ", #{n} warning(s)"

  defp hint(:fail, "dns"),
    do: "point #{Pesque.hostname()} at this server's public IP with an A record"

  defp hint(:warn, "dns"), do: "add an A record before going live"

  defp hint(:fail, "describeServer"),
    do: "check the proxy forwards to the server and that PDS_HOSTNAME is the domain clients use"

  defp hint(:fail, "did document"),
    do: "the domain publishes a different key; restart the server and check PDS_HOSTNAME"

  defp hint(:fail, "plc document"),
    do: "the PLC directory has not published this key yet; wait a moment and retry"

  defp hint(:fail, "handle"),
    do:
      "add the _atproto DNS TXT record, or serve /.well-known/atproto-did at the handle's domain"

  defp hint(_status, _title), do: nil

  defp label(:ok), do: "  ok "
  defp label(:warn), do: "warn"
  defp label(:fail), do: "fail"

  defp config_check do
    detail =
      "mode=#{Pesque.mode()} identity=#{Pesque.identity()} hostname=#{Pesque.hostname()} " <>
        "base_url=#{Pesque.base_url()} handle=#{Identity.handle()} did=#{Identity.did()}"

    if Pesque.hostname_is_ip?() do
      {:warn, "configuration", detail <> " (hostname is an IP literal; handles will not resolve)"}
    else
      {:ok, "configuration", detail}
    end
  end

  defp dns_check(resolver) do
    host = Pesque.hostname()

    cond do
      Pesque.hostname_is_ip?() ->
        {:fail, "dns", "#{host} is an IP literal, not a DNS name"}

      host == "localhost" ->
        {:warn, "dns", "hostname is localhost; nothing outside this machine can resolve it"}

      true ->
        case resolver.(host) do
          {:ok, addresses} -> {:ok, "dns", "#{host} -> #{Enum.join(addresses, ", ")}"}
          :error -> {:fail, "dns", "#{host} does not resolve"}
        end
    end
  end

  defp describe_check(http) do
    url = Pesque.base_url() <> "/xrpc/com.atproto.server.describeServer"

    with {:ok, 200, body} <- http.(url),
         {:ok, %{"did" => did}} <- JSON.decode(body) do
      if did == Identity.did() do
        {:ok, "describeServer", "#{url} answers did=#{did}"}
      else
        {:fail, "describeServer",
         "#{url} answers did=#{inspect(did)}, expected #{Identity.did()}"}
      end
    else
      {:ok, status, _body} ->
        {:fail, "describeServer", "#{url} answered HTTP #{status}"}

      {:error, reason} ->
        {:fail, "describeServer", "#{url} could not be reached: #{inspect(reason)}"}

      _other ->
        {:fail, "describeServer", "#{url} answered something that is not a JSON object"}
    end
  end

  # A did:web document is served here; a did:plc document is served by the
  # directory, so the check follows the DID method to whichever host owns it.
  defp did_document_check(http) do
    if Pesque.identity() == :plc do
      check_document(http, plc_document_url(), "plc document")
    else
      check_document(http, Pesque.base_url() <> "/.well-known/did.json", "did document")
    end
  end

  defp plc_document_url do
    String.trim_trailing(Pesque.plc_directory(), "/") <> "/" <> Identity.did()
  end

  defp check_document(http, url, title) do
    with {:ok, 200, body} <- http.(url),
         {:ok, document} <- JSON.decode(body) do
      published = published_key(document)

      if published == Identity.public_key_multibase() do
        {:ok, title, "#{url} publishes the server key"}
      else
        {:fail, title,
         "#{url} publishes #{inspect(published)}, expected #{inspect(Identity.public_key_multibase())}"}
      end
    else
      {:ok, status, _body} ->
        {:fail, title, "#{url} answered HTTP #{status}"}

      {:error, reason} ->
        {:fail, title, "#{url} could not be reached: #{inspect(reason)}"}

      _other ->
        {:fail, title, "#{url} answered something that is not a JSON object"}
    end
  end

  defp handle_check(resolves) do
    handle = Identity.handle()
    did = Identity.did()

    if resolves.(handle, did) do
      {:ok, "handle", "#{handle} resolves back to #{did}"}
    else
      {:fail, "handle",
       "#{handle} does not resolve to #{did} (set DNS TXT _atproto.#{handle} or serve " <>
         "https://#{handle}/.well-known/atproto-did)"}
    end
  end

  # The #atproto key of the document's verificationMethod, which is the one a
  # peer checks a commit against.
  defp published_key(%{"verificationMethod" => methods}) when is_list(methods) do
    Enum.find_value(methods, fn
      %{"id" => id, "publicKeyMultibase" => key} when is_binary(id) ->
        if String.ends_with?(id, "#atproto"), do: key

      _method ->
        nil
    end)
  end

  defp published_key(_document), do: nil

  defp resolve(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addresses} when addresses != [] -> {:ok, Enum.map(addresses, &format_address/1)}
      _other -> :error
    end
  end

  defp format_address(address), do: address |> :inet.ntoa() |> to_string()

  defp http_get(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), []}

    options = [
      timeout: 10_000,
      connect_timeout: 5_000,
      ssl: ssl_options(),
      autoredirect: false
    ]

    case :httpc.request(:get, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:ok, status, IO.iodata_to_binary(body)}

      {:error, reason} ->
        {:error, reason}
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
