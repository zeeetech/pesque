defmodule Pesque.Cli.Config do
  @moduledoc """
  Configuration verbs. Neither boots: validate reads the file and the
  environment the way the server will at boot (an invalid config would kill a
  boot before anything could report it), and template prints the example file
  the settings table generates.
  """

  alias Pesque.Cli.Input
  alias Pesque.Config

  @usage """
  usage: pesque config validate
         pesque config template [--out PATH]
  """

  def run(["validate" | argv]) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Config.validate_env(),
         {:ok, entries} <- Config.resolution() do
      IO.puts("config file: #{Config.path()}")
      IO.puts("")
      Enum.each(entries, &print_entry/1)
      :ok
    end
  end

  def run(["template" | argv]) do
    with {:ok, opts, []} <- Input.options(argv, [out: :string], @usage) do
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

  # One line per key: the value when it comes from the environment or the
  # file, and the layer that decided it. This is the answer to "why is the
  # server behaving like the file I edited does not exist" - the environment
  # was winning.
  defp print_entry({key, {:env, name, value}}) do
    IO.puts(row(key, inspect(value), "env #{name}"))
  end

  defp print_entry({key, {:file, line, value}}) do
    IO.puts(row(key, inspect(value), "#{Config.path()}:#{line}"))
  end

  defp print_entry({key, :default}) do
    IO.puts(row(key, "", "(default)"))
  end

  defp row(key, value, source) do
    String.pad_trailing(key, 24) <> String.pad_trailing(value, 44) <> source
  end
end
