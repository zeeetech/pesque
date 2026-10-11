defmodule Mix.Tasks.Pesque.Backup do
  @shortdoc "Backs up the data directory to an archive"

  @moduledoc """
  Writes a backup archive of the data directory, the same code
  `bin/pesque backup` runs.

      mix pesque.backup [--out DIR]

  Live-safe: the database is snapshotted with VACUUM INTO first, and the
  file-before-row upload order is what makes the rest safe on a running
  server.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["backup" | argv])
end
