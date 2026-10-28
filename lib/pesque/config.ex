defmodule Pesque.Config do
  @moduledoc """
  The server's configuration file, and the only place server settings are read.

  The file is `key = value`, one per line, `#` for comments. `PDS_CONFIG`
  selects the path; no individual setting has an environment equivalent. The
  grammar and every value are refused when they cannot be read: an unknown or
  retired key fails boot instead of configuring nothing.

  `resolve/2` is the pure layer both boot and `config validate` use. File
  reading and the few environment facts the boundary owns (the config path,
  the release layout, the development-only PLC switch) stay outside it.
  """

  # The settings table. `@keys` is derived from this list, so the parser,
  # resolver and `config validate` cannot disagree about what the file accepts.
  @keys ~w(
    public_url
    port
    data_dir
    mode
    handle_domain
    registration
    crawler
    plc_directory
    lexicon_aggregator
    blob_upload_limit
    repo_import_limit
    proxy_timeout
    proxy_response_limit
    admin_dids
    privacy_policy_url
    terms_of_service_url
  )

  # Values derived from public_url, printed by `config validate` beside the
  # keys the operator wrote.
  @derived_keys ~w(hostname url_scheme url_port)

  @key_atoms for key <- @keys ++ @derived_keys, into: %{}, do: {key, String.to_atom(key)}

  @report_order ~w(
    public_url
    hostname
    url_scheme
    url_port
    port
    data_dir
    mode
    handle_domain
    registration
    crawler
    plc_directory
    lexicon_aggregator
    blob_upload_limit
    repo_import_limit
    proxy_timeout
    proxy_response_limit
    admin_dids
    privacy_policy_url
    terms_of_service_url
  )

  @retired_keys %{
    "hostname" =>
      "set public_url instead; hostname, scheme and advertised port are derived from it",
    "url_scheme" => "set public_url instead; the scheme is derived from it",
    "url_port" => "set public_url instead; the advertised port is derived from it",
    "handle" => "set handle_domain instead; single publishes that domain as the account handle",
    "serve" => "remove it; one-off commands already start without the HTTP endpoint"
  }

  @base_env ~w(PDS_CONFIG)
  @development_env ~w(PDS_PLC_LOCAL)

  @origin_expectation "must be an HTTP or HTTPS origin with a host and optional port, and no credentials, path, query or fragment"
  @port_expectation "must be an integer between 1 and 65535"
  @positive_expectation "must be a positive integer"
  @mode_expectation "must be single or multi"
  @registration_expectation "must be open or closed"
  @lexicon_expectation "must be an https URL or empty"

  @template """
  # pesque configuration. Full reference: docs/installation.md#configuration
  #
  # Public address, behind your TLS proxy.
  public_url = https://pds.example.com

  # Defaults: one account, registration closed.
  # Use multi for multiple accounts or migration from another PDS.
  # mode = multi

  # Optional separate domain: alice.example.com.
  # handle_domain = example.com

  # Optional relay announcements.
  # crawler = https://bsky.network
  """

  @doc "The config file path: `PDS_CONFIG`, or `pesque.conf` in the working directory."
  def path, do: System.get_env("PDS_CONFIG", "pesque.conf")

  @doc """
  Reads the file into `%{key => {value, line}}`.

  A missing file is an empty map, because a source checkout may run with
  built-in development defaults. A release without `public_url` is refused
  by `resolve/2` instead of silently advertising localhost.
  """
  def load do
    case File.read(path()) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:unreadable, path(), reason}}
    end
  end

  @doc "Reads the file, raising a message that names it and the line at fault."
  def load! do
    case load() do
      {:ok, values} -> values
      {:error, reason} -> raise "config file #{path()} is invalid: #{describe(reason)}"
    end
  end

  @doc "Parses the text into `%{key => {value, line}}`, or an error naming the line."
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, key, value} ->
          cond do
            Map.has_key?(@retired_keys, key) ->
              {:halt, {:error, {:retired_key, key, number, @retired_keys[key]}}}

            key not in @keys ->
              {:halt, {:error, {:unknown_key, key, number}}}

            List.keymember?(acc, key, 0) ->
              {:halt, {:error, {:duplicate_key, key, number}}}

            true ->
              {:cont, {:ok, [{key, value, number} | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, {reason, number}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Map.new(acc, fn {key, value, line} -> {key, {value, line}} end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fails boot when the environment carries a `PDS_*` variable nothing reads.

  The file layer refuses unknown and retired keys, and the environment is held
  to the same rule: a variable in a unit file or container environment must
  not configure nothing and boot anyway. `PDS_CONFIG` is the one production
  variable; `PDS_PLC_LOCAL` is allowed only in development and test.
  """
  def validate_env do
    known =
      MapSet.new(@base_env ++ if(development?(), do: @development_env, else: []))

    unknown =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "PDS_"))
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.sort()

    case unknown do
      [] -> :ok
      unknown -> {:error, {:unknown_env, unknown}}
    end
  end

  @doc "Validates the environment, raising a message that names the variables."
  def validate_env! do
    case validate_env() do
      :ok -> :ok
      {:error, reason} -> raise "invalid environment: #{describe(reason)}"
    end
  end

  @doc "The built-in defaults, including the defaults that depend on the release layout."
  def defaults do
    %{
      "public_url" => if(development?(), do: "http://localhost:4000"),
      "port" => "4000",
      "data_dir" => default_data_dir(),
      "mode" => "single",
      "handle_domain" => nil,
      "registration" => "closed",
      "crawler" => "",
      "plc_directory" => "https://plc.directory",
      "lexicon_aggregator" => "",
      "blob_upload_limit" => "5242880",
      "repo_import_limit" => "104857600",
      "proxy_timeout" => "15000",
      "proxy_response_limit" => "10485760",
      "admin_dids" => "",
      "privacy_policy_url" => "",
      "terms_of_service_url" => ""
    }
  end

  @doc """
  Normalizes and validates the file into the settings boot uses.

  Pure: it takes the parsed file and the defaults, and returns either the
  effective settings or a reason naming the setting. `hostname`,
  `url_scheme` and `url_port` are derived from `public_url`; the listening
  `port` stays separate because a proxy may terminate TLS on another port.
  """
  def resolve(file, defaults \\ defaults()) do
    public = fetch(file, defaults, "public_url")

    with {:ok, origin} <- origin(public),
         {:ok, port} <-
           integer(fetch(file, defaults, "port"), "port", 1, 65_535, @port_expectation),
         {:ok, mode} <-
           enum(
             fetch(file, defaults, "mode"),
             "mode",
             %{"single" => :single, "multi" => :multi},
             @mode_expectation
           ),
         {:ok, registration} <-
           enum(
             fetch(file, defaults, "registration"),
             "registration",
             %{"open" => :open, "closed" => :closed},
             @registration_expectation
           ),
         {:ok, blob_upload_limit} <-
           integer(
             fetch(file, defaults, "blob_upload_limit"),
             "blob_upload_limit",
             1,
             nil,
             @positive_expectation
           ),
         {:ok, repo_import_limit} <-
           integer(
             fetch(file, defaults, "repo_import_limit"),
             "repo_import_limit",
             1,
             nil,
             @positive_expectation
           ),
         {:ok, proxy_timeout} <-
           integer(
             fetch(file, defaults, "proxy_timeout"),
             "proxy_timeout",
             1,
             nil,
             @positive_expectation
           ),
         {:ok, proxy_response_limit} <-
           integer(
             fetch(file, defaults, "proxy_response_limit"),
             "proxy_response_limit",
             1,
             nil,
             @positive_expectation
           ),
         {:ok, lexicon_aggregator} <-
           lexicon(fetch(file, defaults, "lexicon_aggregator")) do
      handle_domain = handle_domain(fetch(file, defaults, "handle_domain"), origin.host)

      {:ok,
       %{
         public_url: origin.url,
         hostname: origin.host,
         url_scheme: origin.scheme,
         url_port: origin.port,
         port: port,
         data_dir: value(fetch(file, defaults, "data_dir")),
         mode: mode,
         handle_domain: handle_domain,
         registration: registration,
         crawler: list(fetch(file, defaults, "crawler")),
         plc_directory: value(fetch(file, defaults, "plc_directory")),
         lexicon_aggregator: lexicon_aggregator,
         blob_upload_limit: blob_upload_limit,
         repo_import_limit: repo_import_limit,
         proxy_timeout: proxy_timeout,
         proxy_response_limit: proxy_response_limit,
         admin_dids: list(fetch(file, defaults, "admin_dids")),
         privacy_policy_url: value(fetch(file, defaults, "privacy_policy_url")),
         terms_of_service_url: value(fetch(file, defaults, "terms_of_service_url"))
       }}
    end
  end

  @doc "Reads and resolves the effective configuration."
  def effective do
    with {:ok, file} <- load(), do: resolve(file)
  end

  @doc "Reads and resolves the effective configuration, raising on an invalid one."
  def effective! do
    case effective() do
      {:ok, settings} -> settings
      {:error, reason} -> raise "config file #{path()} is invalid: #{describe(reason)}"
    end
  end

  @doc """
  Where every effective value came from, for `config validate`: one entry per
  setting and derived value, in report order. `resolve/2` runs first, so an
  invalid value is reported here instead of surfacing as a failed boot.
  """
  def resolution do
    with {:ok, file} <- load(),
         {:ok, settings} <- resolve(file) do
      {:ok, Enum.map(@report_order, &{&1, setting(settings, &1), source(&1, file)})}
    end
  end

  @doc "The example configuration file, kept short on purpose."
  def template, do: @template

  @doc """
  Whether this process is running from a checkout in development or test.

  A release, or a `MIX_ENV=prod` source run, is a deployment: it has to name
  `public_url` instead of inheriting the localhost default.
  """
  def development? do
    release_root() == nil and mix_env() in [:dev, :test]
  end

  @doc false
  def default_data_dir do
    cond do
      release_root() != nil -> "/data"
      mix_env() == :test -> "tmp/test"
      true -> "data"
    end
  end

  # Mix.env/0 is the source of truth in a checkout. A release does not carry
  # Mix, so the module is absent and the release layout wins.
  defp mix_env do
    if Code.ensure_loaded?(Mix) do
      Mix.env()
    else
      :prod
    end
  end

  defp release_root do
    case System.get_env("RELEASE_ROOT") do
      nil -> nil
      "" -> nil
      _root -> :release
    end
  end

  defp fetch(file, defaults, key) do
    case Map.get(file, key) do
      {value, line} -> {value, line}
      value when is_binary(value) -> {value, nil}
      nil -> {Map.get(defaults, key), nil}
    end
  end

  defp value({value, _line}), do: value

  defp origin({nil, _line}) do
    {:error,
     {:missing_setting, "public_url",
      "set public_url in pesque.conf; it is the one required server setting"}}
  end

  defp origin({raw, line}) do
    with {:ok, uri} <- URI.new(String.trim(raw)),
         true <- origin?(uri) do
      {:ok,
       %{
         url: uri |> Map.put(:path, nil) |> URI.to_string(),
         scheme: uri.scheme,
         host: uri.host,
         port: uri.port
       }}
    else
      _other -> {:error, {:invalid_setting, "public_url", raw, @origin_expectation, line}}
    end
  end

  defp origin?(%URI{
         scheme: scheme,
         host: host,
         userinfo: nil,
         query: nil,
         fragment: nil,
         port: port,
         path: path
       })
       when scheme in ["http", "https"] and is_binary(host) and host != "" and
              is_integer(port) and port > 0 and port <= 65_535 and path in [nil, "", "/"] do
    true
  end

  defp origin?(_uri), do: false

  defp integer({raw, line}, key, min, max, expectation) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number >= min and (is_nil(max) or number <= max) -> {:ok, number}
      _other -> {:error, {:invalid_setting, key, raw, expectation, line}}
    end
  end

  defp integer({raw, line}, key, _min, _max, expectation) do
    {:error, {:invalid_setting, key, raw, expectation, line}}
  end

  defp enum({raw, line}, key, values, expectation) do
    case Map.fetch(values, raw) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_setting, key, raw, expectation, line}}
    end
  end

  defp lexicon({raw, _line}) when raw in [nil, ""], do: {:ok, nil}

  defp lexicon({"https://" <> _rest = raw, _line}), do: {:ok, raw}

  defp lexicon({raw, line}) do
    {:error, {:invalid_setting, "lexicon_aggregator", raw, @lexicon_expectation, line}}
  end

  defp handle_domain({nil, _line}, hostname), do: String.downcase(hostname)
  defp handle_domain({raw, _line}, _hostname), do: String.downcase(raw)

  defp list({raw, _line}) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp setting(settings, key), do: Map.fetch!(settings, Map.fetch!(@key_atoms, key))

  defp source(key, file) do
    case Map.get(file, key) do
      {_value, line} ->
        {:file, line}

      nil ->
        cond do
          key in @derived_keys -> {:derived, "public_url"}
          key == "handle_domain" -> {:derived, "public_url"}
          key == "public_url" -> :development_default
          true -> :default
        end
    end
  end

  defp parse_line(line) do
    [before | _comment] = String.split(line, "#", parts: 2)

    case String.split(before, "=", parts: 2) do
      [key, value] -> build(String.trim(key), String.trim(value))
      [_no_equals] -> if String.trim(before) == "", do: :skip, else: {:error, :invalid_line}
    end
  end

  defp build("", _value), do: {:error, :invalid_line}
  defp build(_key, ""), do: {:error, :missing_value}
  defp build(key, value), do: {:ok, key, value}

  defp describe({:unknown_env, names}) do
    "unknown PDS_ variables in the environment: " <>
      Enum.join(names, ", ") <>
      ". Server settings live in #{path()}; PDS_CONFIG only selects the file, " <>
      "and PDS_PLC_LOCAL is development-only."
  end

  defp describe({:retired_key, key, line, advice}),
    do: "retired key #{inspect(key)} on line #{line}: #{advice}"

  defp describe({:unknown_key, key, line}),
    do: "unknown key #{inspect(key)} on line #{line}; see docs/installation.md#configuration"

  defp describe({:duplicate_key, key, line}), do: "duplicate key #{inspect(key)} on line #{line}"

  defp describe({:missing_setting, key, advice}), do: "#{key} is required: #{advice}"

  defp describe({:invalid_setting, key, value, expectation, line}) do
    where = if line, do: " on line #{line}", else: ""
    "#{key} #{expectation}, got #{inspect(value)}#{where}"
  end

  defp describe({reason, line}), do: "#{reason} on line #{line}"
  defp describe({:unreadable, path, reason}), do: "cannot read #{path}: #{inspect(reason)}"
end
