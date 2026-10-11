defmodule Pesque.Cli.Backup do
  @moduledoc """
  Writes a backup archive of the data directory. Live-safe: the database is
  snapshotted first and the file-before-row upload order is what makes the
  rest safe on a running server.
  """

  alias Pesque.Backup
  alias Pesque.Cli.Input
  alias Pesque.Release

  @usage "usage: pesque backup [--out DIR]"

  def run(argv) do
    with {:ok, opts, []} <- Input.options(argv, [out: :string], @usage),
         :ok <- Release.boot!() do
      case Backup.create(Pesque.data_dir(), opts[:out] || File.cwd!()) do
        {:ok, archive} ->
          IO.puts("wrote #{archive}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
