defmodule Pesque.Cli.Lexicon do
  @moduledoc """
  Installs the lexicons a third-party repository carries into `data/lexicons`.

  `--from` is a local checkout, not a URL: the CLI resolves a git URL to one
  before forwarding (the release image carries no git), so this verb only ever
  reads a directory it was handed. It boots like the other verbs that touch the
  data directory, which is what resolves `data_dir` from the configuration;
  writing the files is the whole job, and the CLI restarts the service
  afterwards to load them.
  """

  alias Pesque.Cli.Input
  alias Pesque.Lexicon.Install
  alias Pesque.Lexicon.Registry
  alias Pesque.Release

  @usage """
  usage: pesque lexicon add --from DIR [--dir SUBPATH]
  """

  def run(["add" | argv]) do
    with {:ok, opts, []} <- Input.options(argv, [from: :string, dir: :string], @usage),
         {:ok, from} <- source(opts[:from]),
         :ok <- Release.boot!(),
         {:ok, documents} <- Install.discover(from, dir: opts[:dir]),
         {:ok, written} <- Install.install(documents, Registry.user_dir()) do
      report(documents, written, Registry.user_dir())
    end
  end

  def run(_argv), do: {:usage, @usage}

  defp source(nil), do: {:usage, "lexicon add needs --from DIR\n\n" <> @usage}
  defp source(dir), do: {:ok, dir}

  defp report(documents, written, target) do
    case map_size(documents) do
      0 ->
        IO.puts("no lexicons found; nothing written to #{target}")
        :ok

      count ->
        IO.puts("installed #{count} lexicons into #{target}:")
        written |> Enum.sort() |> Enum.each(&IO.puts("  #{&1}"))
        :ok
    end
  end
end
