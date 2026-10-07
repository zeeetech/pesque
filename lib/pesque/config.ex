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
  otherwise silently lose to the first.

  The path is `PDS_CONFIG`, or `pesque.conf` in the working directory. The
  container sets it to `/data/pesque.conf`, on the volume, so mounting one file
  is enough to configure it.
  """

  @keys ~w(
    data_dir hostname handle port url_scheme url_port mode identity
    plc_directory crawler handle_domain registration blob_upload_limit
    repo_import_limit admin_dids
  )

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
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        :skip ->
          {:cont, {:ok, acc}}

        {:ok, key, value} ->
          cond do
            key not in @keys -> {:halt, {:error, {:unknown_key, key, number}}}
            Map.has_key?(acc, key) -> {:halt, {:error, {:duplicate_key, key, number}}}
            true -> {:cont, {:ok, Map.put(acc, key, value)}}
          end

        {:error, reason} ->
          {:halt, {:error, {reason, number}}}
      end
    end)
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
