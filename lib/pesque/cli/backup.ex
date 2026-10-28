defmodule Pesque.Cli.Backup do
  @moduledoc """
  Writes a backup archive of the data directory. Live-safe: the database is
  snapshotted first, and blob uploads write the file before the row, so a
  race with a running upload can only leave an orphan file in the archive.
  """

  alias Pesque.Backup
  alias Pesque.Cli.Input
  alias Pesque.Cli.Runtime

  @usage "usage: pesque backup [--out DIR]"

  def run(argv) do
    with {:ok, opts, []} <- Input.options(argv, [out: :string], @usage),
         :ok <- Runtime.start() do
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
