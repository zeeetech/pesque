defmodule Pesque.Config do
  @moduledoc """
  The base configuration layer: a small `key = value` file, read once at boot.

  Precedence is environment, then file, then the default in `config/runtime.exs`.
  The environment wins so container and systemd deployments keep working
  unchanged, and the file is where a longer list of settings is easier to read
  than a wall of `-e` flags.

  The grammar is deliberately tiny: `#` starts a comment, blank lines are
  ignored, and a line is `key = value` with whitespace around either side
  dropped. A key the server does not know is an error, so a typo fails boot
  instead of being ignored, and so is a repeated key, whose second value would
  otherwise silently lose to the first. The environment layer is held to the
  same rule by `validate_env/0`: an unknown `PDS_*` variable fails boot rather
  than configuring nothing.

  The path is `PDS_CONFIG`, or `pesque.conf` in the working directory. The
  container sets it to `/data/pesque.conf`, on the volume, so mounting one file
  is enough to configure it.
  """

  # The settings table, in the order the template prints them: the key, the
  # example value it carries, whether the line is live or shown as a
  # commented default, and the prose above it. `@keys` is derived from this
  # list, so a key added here is checked by the parser, resolved by get/3's
  # callers and offered by `config template` in the same change.
  @settings [
    {"hostname", "pds.example.com", :set, "The host this server is reached at."},
    {"mode", "path_multi", :set,
     "conformant_single serves one account as the server itself. path_multi\ngives every account its own handle and DID."},
    {"identity", "plc", :set,
     "web mints did:web accounts from the hostname. plc mints did:plc through\nthe PLC directory, and requires mode = path_multi."},
    {"handle_domain", "example.com", :set, "The domain accounts get handles under."},
    {"registration", "closed", :set,
     "open lets anyone create an account; closed needs an invite code."},
    {"crawler", "https://bsky.network", :default,
     "Relays to announce this server to at boot, comma separated. Unset (or\nempty) asks nobody."},
    {"data_dir", "data", :default,
     "Where the database, keys, blobs and secret live. A relative path is\nrelative to the working directory."},
    {"handle", "pds.example.com", :default,
     "What conformant_single publishes as the account's handle. Defaults to\nthe hostname; path_multi ignores it."},
    {"port", "4000", :default, "The port this process listens on."},
    {"url_scheme", "https", :default,
     "The scheme clients are told to reach this server at. The container\nspeaks plain HTTP behind a TLS proxy, so https is the arrangement the\ndefaults expect."},
    {"url_port", "443", :default,
     "The advertised port. Defaults to 443 under https, and to port otherwise."},
    {"plc_directory", "https://plc.directory", :default,
     "The PLC directory. Only read when identity = plc."},
    {"blob_upload_limit", "5242880", :default,
     "The largest uploadBlob accepts, in bytes. 5242880 is 5 MiB."},
    {"repo_import_limit", "104857600", :default,
     "The largest importRepo accepts, in bytes. 104857600 is 100 MiB."},
    {"proxy_timeout", "15000", :default,
     "How long a proxied call may take before it is answered 504, in\nmilliseconds."},
    {"proxy_response_limit", "10485760", :default,
     "The largest body a proxied call may return, in bytes."},
    {"admin_dids", "did:plc:...,did:web:...", :default,
     "The operators, comma separated: the callers the admin endpoints answer.\nEmpty means the server identity under conformant_single, and nobody\nunder path_multi."},
    {"privacy_policy_url", "https://example.com/privacy", :default,
     "Your own privacy policy, published by describeServer. Unset means the\nlinks map omits it, which is right when you have none to stand behind."},
    {"terms_of_service_url", "https://example.com/terms", :default,
     "Your own terms of service, published by describeServer. Unset means the\nlinks map omits it."},
    {"metrics_token", "", :default,
     "The token GET /metrics requires as its bearer, which is the server's\nPrometheus exposition. Empty (the default) turns the endpoint off: it\nanswers 404. The endpoint is for your own collector, unpublished by\nCaddy; see Metrics and monitoring in docs/guides/operations.md."},
    {"serve", "true", :default,
     "Whether to start the HTTP endpoint. The one-off verbs set PDS_SERVE=false\nso they do not fight the running server for the port; leave this unset."}
  ]

  @keys for {key, _value, _shown, _prose} <- @settings, do: key

  # The internal PDS_* variables the tooling sets around the server's own
  # config keys. PDS_SERVE needs no entry (serve is a config key); the
  # wrapper and image set these three, and nothing else may use the
  # namespace, because a PDS_* variable nothing reads is a typo that
  # configured nothing.
  @internal_env ~w(PDS_CONFIG PDS_PUBLIC_IP PDS_TAG)

  @template_header """
  # pesque configuration.
  #
  # Every setting here can also come from the environment, and the environment
  # wins. The variable is this key uppercased with a PDS_ prefix, so `hostname`
  # is `PDS_HOSTNAME` and `port` is `PDS_PORT`.
  #
  # Point the server at this file with PDS_CONFIG, or leave it as `pesque.conf`
  # in the working directory. In the container the path is /data/pesque.conf, on
  # the volume, so mounting one file is enough.
  #
  # Generated by `pesque config template`; the keys it offers are the keys the
  # server reads.

  """

  @doc "The config file path: `PDS_CONFIG`, or `pesque.conf` in the working directory."
  def path, do: System.get_env("PDS_CONFIG", "pesque.conf")

  @doc """
  Reads the file.

  A missing file is an empty map, because a deployment that configures
  everything through the environment is a normal deployment, not an error.
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

  @doc "Parses the text into `%{key => value}`, or an error naming the line."
  def parse(text) when is_binary(text) do
    with {:ok, entries} <- parse_lines(text) do
      {:ok, Map.new(entries, fn {key, value, _line} -> {key, value} end)}
    end
  end

  @doc """
  Fails boot when the environment carries a `PDS_*` variable nothing reads.

  The file layer refuses an unknown key (a typo must fail boot rather than be
  ignored); until now the environment was the one layer that stayed silent,
  so a misspelled variable in a unit file or compose environment configured
  nothing and booted anyway. The allowlist is the config keys plus the
  internal variables the release tooling sets around them.
  """
  def validate_env do
    known = MapSet.new(Enum.map(@keys, &("PDS_" <> String.upcase(&1))) ++ @internal_env)

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
      :ok ->
        :ok

      {:error, {:unknown_env, names}} ->
        raise "unknown PDS_ variables in the environment: " <>
                Enum.join(names, ", ") <>
                ". A variable the server reads is a config key uppercased with a PDS_ " <>
                "prefix (pesque.conf.example lists them all), and the internal ones the " <>
                "tooling sets are PDS_CONFIG, PDS_PUBLIC_IP and PDS_TAG."
    end
  end

  @doc """
  Where every key is set, for `config validate`: one entry per key in the
  table's order, whose source is `{:env, name, value}`, `{:file, line,
  value}` or `:default`. An empty environment value reads as unset, the same
  rule get/3 applies.
  """
  def resolution do
    case load_with_lines() do
      {:ok, file} -> {:ok, Enum.map(@keys, &resolve(&1, file))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The example configuration file, generated from the settings table so the
  two cannot drift. `config template` prints it (or writes it with --out),
  and the committed `pesque.conf.example` is this output kept under version
  control.
  """
  def template do
    @template_header <>
      (@settings |> Enum.map(&setting_template/1) |> IO.iodata_to_binary())
  end

  @doc """
  One setting: the environment first, then the file, then the default.

  The environment variable is `PDS_` plus the key uppercased, so `port` is
  `PDS_PORT` and the two layers need no second vocabulary. Lists are a
  comma-separated string in either layer and are split by the caller.
  """
  def get(file, key, default) do
    System.get_env("PDS_" <> String.upcase(key)) || Map.get(file, key) || default
  end

  defp resolve(key, file) do
    name = "PDS_" <> String.upcase(key)
    env = System.get_env(name)

    cond do
      env != nil and env != "" ->
        {key, {:env, name, env}}

      entry = Map.get(file, key) ->
        {key, {:file, elem(entry, 1), elem(entry, 0)}}

      true ->
        {key, :default}
    end
  end

  defp setting_template({key, value, shown, prose}) do
    comment =
      prose
      |> String.split("\n")
      |> Enum.map_join("\n", &("# " <> &1))

    line = if shown == :set, do: "#{key} = #{value}", else: "# #{key} = #{value}"

    comment <> "\n" <> line <> "\n\n"
  end

  # load/0's walk with the line each key was read from, so provenance can
  # point at where a setting was written.
  defp load_with_lines do
    case File.read(path()) do
      {:ok, text} -> parse_with_lines(text)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:unreadable, path(), reason}}
    end
  end

  defp parse_with_lines(text) when is_binary(text) do
    with {:ok, entries} <- parse_lines(text) do
      {:ok, Map.new(entries, fn {key, value, line} -> {key, {value, line}} end)}
    end
  end

  defp parse_lines(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, key, value} ->
          cond do
            key not in @keys -> {:halt, {:error, {:unknown_key, key, number}}}
            List.keymember?(acc, key, 0) -> {:halt, {:error, {:duplicate_key, key, number}}}
            true -> {:cont, {:ok, [{key, value, number} | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, {reason, number}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
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

  defp describe({:unknown_key, key, line}), do: "unknown key #{inspect(key)} on line #{line}"
  defp describe({:duplicate_key, key, line}), do: "duplicate key #{inspect(key)} on line #{line}"
  defp describe({reason, line}), do: "#{reason} on line #{line}"
  defp describe({:unreadable, path, reason}), do: "cannot read #{path}: #{inspect(reason)}"
end
