defmodule Pesque.Cli.Config do
  @moduledoc """
  Configuration verbs. Neither boots: an invalid config would kill a boot
  before anything could report it, so validate reads the file the way the
  server will at boot, then prints every effective value with its source.
  """

  alias Pesque.Cli.Input
  alias Pesque.Config

  @usage """
  usage: pesque config validate
         pesque config template [--out PATH]
  """

  @validate_usage "usage: pesque config validate"
  @template_usage "usage: pesque config template [--out PATH]"

  def run(["--help"]), do: {:help, @usage}

  def run(["validate" | argv]) do
    with {:ok, _opts, []} <- Input.options(argv, [], @validate_usage),
         :ok <- Config.validate_env(),
         {:ok, entries} <- Config.resolution() do
      IO.puts("config file: #{Config.path()}")
      IO.puts("")
      Enum.each(entries, &print_entry/1)
      :ok
    end
  end

  def run(["template" | argv]) do
    with {:ok, opts, []} <- Input.options(argv, [out: :string], @template_usage) do
      write(opts[:out], Config.template())
    end
  end

  def run(_argv), do: {:usage, @usage}

  defp write(nil, text) do
    IO.write(text)
    :ok
  end

  defp write(out, text) do
    case File.write(out, text) do
      :ok ->
        IO.puts("wrote #{out}")
        :ok

      {:error, reason} ->
        {:error, {:unwritable, out, reason}}
    end
  end

  # One line per effective setting with the layer that decided it: the file,
  # a built-in default, the development default, or public_url for a derived
  # value.
  defp print_entry({key, value, source}) do
    IO.puts(row(key, format(value), source_text(source)))
  end

  defp source_text({:file, line}), do: "#{Config.path()}:#{line}"
  defp source_text(:default), do: "(default)"
  defp source_text(:development_default), do: "(development default)"
  defp source_text({:derived, key}), do: "(derived from #{key})"

  defp format(nil), do: ""
  defp format(values) when is_list(values), do: Enum.join(values, ",")
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)

  defp row(key, value, source) do
    String.pad_trailing(key, 24) <> String.pad_trailing(value, 44) <> source
  end
end
