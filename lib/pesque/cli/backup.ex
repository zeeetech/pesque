defmodule Pesque.Cli.Backup do
  @moduledoc """
  Writes a backup archive of the data directory. Live-safe: the database is
  snapshotted first, and blob uploads write the file before the row, so a
  race with a running upload can only leave an orphan file in the archive.

  Cold on purpose: the archive is the database's own snapshot plus the files
  beside it, taken outside the application. Nothing here reads through the
  Repo or an endpoint, so the verb starts no application: it runs against a
  data directory a live server holds, and against a stopped one the same way.
  The paths are the operator's: `data_dir` and `--out` come from the
  provider-installed configuration, unchanged.
  """

  alias Pesque.Backup
  alias Pesque.Cli.Input

  @usage "usage: pesque backup [--out DIR]"

  def run(argv) do
    with {:ok, opts, []} <- Input.options(argv, [out: :string], @usage) do
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
