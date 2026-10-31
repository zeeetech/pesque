defmodule Pesque.Config do
  @moduledoc """
  The server's configuration file, and the only place server settings are read.

  The file is `key = value`, one per line, `#` for comments. `PDS_CONFIG`
  selects the path. The grammar and every value are refused when they cannot be
  read: an unknown key fails boot instead of configuring nothing.
  """

  @behaviour Config.Provider

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          url_scheme: :http | :https,
          hostname: String.t(),
          port: integer,
          data_dir: Path.t(),
          mode: :single | :multi,
          handle_domain: String.t(),
          registration: :open | :closed,
          crawler: list(URI.t()),
          plc_directory: URI.t(),
          lexicon_aggregator: URI.t() | nil,
          blob_upload_limit: integer,
          repo_import_limit: integer,
          proxy_timeout: integer,
          proxy_response_limit: integer,
          admin_dids: list(String.t()) | nil,
          privacy_policy_url: URI.t() | nil,
          terms_of_service_url: URI.t() | nil
        }

  @port_expectation "must be an integer between 1 and 65535"
  @host_expectation "is invalid"
  @lexicon_expectation "must be an https URL or empty"

  @template """
  # pesque configuration. Full reference: docs/installation.md#configuration
  #
  # Public origin, behind your TLS proxy: scheme://hostname on 443/80.
  url_scheme = https
  hostname = pds.example.com

  # Port the process binds. Internal behind the proxy; not in the public URL.
  port = 4000

  # Directory holding the database, keys, blobs and secret.
  data_dir = /data

  # Defaults: one account, registration closed.
  # Use multi for multiple accounts or migration from another PDS.
  # mode = multi

  # Optional separate domain: alice.example.com.
  # handle_domain = example.com

  # Optional relay announcements.
  # crawler = https://bsky.network
  """

  @required ~w(url_scheme hostname port data_dir)a

  @fields ~w(mode handle_domain registration crawler plc_directory lexicon_aggregator blob_upload_limit repo_import_limit proxy_timeout proxy_response_limit admin_dids privacy_policy_url terms_of_service_url)a ++
            @required

  @keys Enum.map(@fields, &to_string/1)

  embedded_schema do
    field :url_scheme, Ecto.Enum, values: ~w(http https)a
    field :hostname, :string
    field :port, :integer
    field :data_dir, :string
    field :mode, Ecto.Enum, values: ~w(single multi)a, default: :single
    field :handle_domain, :string
    field :registration, Ecto.Enum, values: ~w(open closed)a, default: :closed
    field :crawler, {:array, __MODULE__.URI}, default: []
    field :plc_directory, __MODULE__.URI, default: "https://plc.directory"
    field :lexicon_aggregator, __MODULE__.URI
    field :blob_upload_limit, :integer, default: 5_242_880
    field :repo_import_limit, :integer, default: 104_857_600
    field :proxy_timeout, :integer, default: 15_000
    field :proxy_response_limit, :integer, default: 10_485_760
    field :admin_dids, {:array, :string}, default: []
    field :privacy_policy_url, __MODULE__.URI
    field :terms_of_service_url, __MODULE__.URI
  end

  @impl true
  def init(_opts), do: {:system, "PDS_CONFIG"}

  @impl true
  def load(config, {:system, name}) do
    path =
      case System.get_env(name) do
        path when path in [nil, ""] -> "pesque.conf"
        path -> path
      end

    settings = effective!(path)

    Config.Reader.merge(config, pesque: pesque_config(settings))
  end

  @doc "The config file path: `PDS_CONFIG`, or `pesque.conf` in the working directory."
  def path do
    case System.get_env("PDS_CONFIG") do
      path when path in [nil, ""] -> "pesque.conf"
      path -> path
    end
  end

  @doc "Parses the text into `%{key => {value, line}}`, or an error naming the line."
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_entry/2)
    |> case do
      {:ok, entries} ->
        {:ok, Map.new(entries, fn {key, value, line} -> {key, {value, line}} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_entry({line, number}, {:ok, entries}) do
    case parse_line(line) do
      :skip -> {:cont, {:ok, entries}}
      {:ok, key, value} -> add_entry(key, value, number, entries)
      {:error, reason} -> {:halt, {:error, {reason, number}}}
    end
  end

  defp add_entry(key, value, number, entries) do
    cond do
      key not in @keys ->
        {:halt, {:error, {:unknown_key, key, number}}}

      List.keymember?(entries, key, 0) ->
        {:halt, {:error, {:duplicate_key, key, number}}}

      true ->
        {:cont, {:ok, [{key, value, number} | entries]}}
    end
  end

  @doc "Reads and resolves the effective configuration."
  def effective(path \\ path()) do
    with {:ok, file} <- read(path), do: resolve(file)
  end

  @doc "Reads and resolves the effective configuration, raising on an invalid one."
  def effective!(path \\ path()) do
    case effective(path) do
      {:ok, settings} ->
        settings

      {:error, {:invalid, _path, _reason} = reason} ->
        raise Pesque.Config.Error, reason

      {:error, reason} ->
        raise Pesque.Config.Error, {:invalid, path, reason}
    end
  end

  @doc "The :pesque application configuration from the file, for source execution."
  def source_config!(path \\ path()) do
    path |> effective!() |> pesque_config()
  end

  @doc "The example configuration file, kept short on purpose."
  def template, do: @template

  @doc "The effective settings in display order."
  def settings(%__MODULE__{} = settings) do
    [
      url_scheme: to_string(settings.url_scheme),
      hostname: host(settings.hostname),
      port: settings.port,
      data_dir: settings.data_dir,
      public_url: origin(settings),
      mode: settings.mode,
      handle_domain: host(settings.handle_domain),
      registration: settings.registration,
      crawler: Enum.map(settings.crawler, &url/1),
      plc_directory: url(settings.plc_directory),
      lexicon_aggregator: url(settings.lexicon_aggregator),
      blob_upload_limit: settings.blob_upload_limit,
      repo_import_limit: settings.repo_import_limit,
      proxy_timeout: settings.proxy_timeout,
      proxy_response_limit: settings.proxy_response_limit,
      admin_dids: settings.admin_dids || [],
      privacy_policy_url: url(settings.privacy_policy_url),
      terms_of_service_url: url(settings.terms_of_service_url)
    ]
  end

  defp resolve(file) do
    attrs =
      file
      |> Map.new(fn {key, {value, _line}} -> {key, value} end)
      |> split_list("crawler")
      |> split_list("admin_dids")

    changeset = changeset(attrs)

    case apply_action(changeset, :insert) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, changeset} ->
        errors =
          changeset
          |> traverse_changeset_errors()
          |> with_lines(file)

        {:error, errors}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> {:error, {:missing_file, path}}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp split_list(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        Map.put(attrs, key, value |> String.split(",", trim: true) |> Enum.map(&String.trim/1))

      _other ->
        attrs
    end
  end

  defp with_lines(errors, file) do
    Map.new(errors, fn {key, message} ->
      case Map.get(file, to_string(key)) do
        {_value, line} -> {key, message <> " on line #{line}"}
        nil -> {key, message}
      end
    end)
  end

  defp pesque_config(settings) do
    [
      {Pesque.Repo, repo_config(settings)},
      {PesqueWeb.Endpoint, endpoint_config(settings)},
      public_url: origin(settings),
      data_dir: settings.data_dir,
      hostname: host(settings.hostname),
      url_scheme: to_string(settings.url_scheme),
      port: settings.port,
      mode: settings.mode,
      handle_domain: host(settings.handle_domain),
      registration: settings.registration,
      plc_directory: url(settings.plc_directory),
      lexicon_aggregator: url(settings.lexicon_aggregator),
      crawlers: Enum.map(settings.crawler, &url/1),
      blob_max_bytes: settings.blob_upload_limit,
      repo_import_max_bytes: settings.repo_import_limit,
      proxy_timeout: settings.proxy_timeout,
      proxy_response_limit: settings.proxy_response_limit,
      privacy_policy_url: url(settings.privacy_policy_url) || "",
      terms_of_service_url: url(settings.terms_of_service_url) || "",
      admin_dids: settings.admin_dids || []
    ]
  end

  defp repo_config(settings) do
    [database: Path.join(settings.data_dir, "pesque.db")]
  end

  defp endpoint_config(settings) do
    scheme = to_string(settings.url_scheme)
    host = host(settings.hostname)

    [
      http: [port: settings.port],
      url: [
        host: host,
        scheme: scheme,
        port: public_port(settings, scheme, host)
      ]
    ]
  end

  defp origin(settings) do
    scheme = to_string(settings.url_scheme)
    host = host(settings.hostname)
    port = public_port(settings, scheme, host)

    if port == URI.default_port(scheme) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  # The listening port is internal when a proxy terminates TLS, so a public
  # host advertises the scheme's default port (443 or 80) instead. Loopback
  # and private hosts have no proxy to assume, so they keep the listening
  # port and source development works unchanged.
  defp public_port(settings, scheme, host) do
    if Pesque.Did.local_host?(host), do: settings.port, else: URI.default_port(scheme)
  end

  defp host(nil), do: nil
  defp host(""), do: nil
  defp host(host), do: host

  defp url(nil), do: nil
  defp url(%URI{} = uri), do: URI.to_string(uri)
  defp url(url), do: url

  defp changeset(%{} = attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> update_change(:hostname, &normalize_host/1)
    |> update_change(:handle_domain, &normalize_host/1)
    |> validate_change(:hostname, &validate_host/2)
    |> validate_change(:handle_domain, &validate_host/2)
    |> update_change(:lexicon_aggregator, &empty_to_nil/1)
    |> validate_required(@required)
    |> validate_number(:port,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 65_535,
      message: @port_expectation
    )
    |> validate_number(:blob_upload_limit, greater_than: 0)
    |> validate_number(:repo_import_limit, greater_than: 0)
    |> validate_number(:proxy_timeout, greater_than: 0)
    |> validate_number(:proxy_response_limit, greater_than: 0)
    |> validate_change(:lexicon_aggregator, fn
      _, nil -> []
      _, %URI{scheme: "https"} -> []
      _, _ -> [@lexicon_expectation]
    end)
    |> maybe_put_handle_domain()
  end

  defp empty_to_nil(%URI{scheme: nil, host: nil, path: path}) when path in [nil, ""], do: nil
  defp empty_to_nil(uri), do: uri

  defp normalize_host(host) when is_binary(host) do
    case URI.new(host) do
      {:ok, %URI{host: parsed_host}} when is_binary(parsed_host) -> parsed_host
      {:ok, %URI{path: path}} when is_binary(path) -> path
      _result -> host
    end
  end

  defp validate_host(field, host) do
    case URI.new(host) do
      {:ok, _uri} -> []
      {:error, _reason} -> [{field, @host_expectation}]
    end
  end

  defp maybe_put_handle_domain(%{valid?: false} = changeset), do: changeset

  defp maybe_put_handle_domain(%Ecto.Changeset{} = changeset) do
    hostname = get_change(changeset, :hostname)
    handle_domain = get_change(changeset, :handle_domain)

    if is_nil(handle_domain) do
      put_change(changeset, :handle_domain, hostname)
    else
      changeset
    end
  end

  defp traverse_changeset_errors(changeset) do
    traverse_errors(changeset, fn {msg, opts} ->
      msg = fold_error(msg, opts)

      type = Keyword.get(opts, :type)

      case type do
        nil ->
          msg

        {:parameterized, {Ecto.Enum, _}} ->
          msg <> ", expected one of [#{Enum.join(opts[:enum], ", ")}]"

        type ->
          msg <> ", expected #{type}"
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.join(v, ", ")} end)
  end

  defp fold_error(msg, opts) do
    Enum.reduce(opts, msg, fn
      {_, {:parameterized, {Ecto.Enum, _}}}, acc ->
        acc

      {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
    end)
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

  @doc false
  def describe({:invalid, path, reason}),
    do: "config file #{path} is invalid:\n" <> describe(reason)

  def describe({:missing_file, path}),
    do: "config file #{path} does not exist; copy pesque.conf.example or set PDS_CONFIG"

  def describe({:unknown_key, key, line}),
    do: "unknown key #{inspect(key)} on line #{line}; see docs/installation.md#configuration"

  def describe({:duplicate_key, key, line}),
    do: "duplicate key #{inspect(key)} on line #{line}"

  def describe({:unreadable, path, reason}), do: "cannot read #{path}: #{inspect(reason)}"

  def describe(%{} = errors) do
    Enum.map_join(errors, "\n", fn {key, message} -> "#{key}: #{message}" end)
  end
end
