defmodule Pesque.Cli.Config do
  @moduledoc """
  Configuration verbs. Neither boots the application: `validate` reads and
  resolves the file the way the provider will, then prints the effective
  settings; `template` writes the example.
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
         {:ok, settings} <- Config.effective() do
      IO.puts("config file: #{Config.path()}")
      IO.puts("")
      Enum.each(Config.settings(settings), &print_setting/1)
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

  defp print_setting({key, value}) do
    IO.puts(String.pad_trailing(to_string(key), 24) <> format(value))
  end

  defp format(nil), do: ""
  defp format(values) when is_list(values), do: Enum.join(values, ",")
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
