defmodule Mix.Tasks.Pesque.Restore do
  @shortdoc "Restores a backup archive over the data directory"

  @moduledoc """
  Restores a backup archive over the data directory, the same code
  `bin/pesque restore` runs.

      mix pesque.restore ARCHIVE.tar.gz

  Cold: the server must be stopped, and the verb refuses while the database
  is locked. A swap that stops partway leaves the previous state in `.old`
  names.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["restore" | argv])
end
