defmodule Mix.Tasks.Pesque.Config do
  @shortdoc "Validates configuration and prints the example file"

  @moduledoc """
  Configuration verbs, the same code `bin/pesque config` runs.

      mix pesque.config validate          # where every setting came from
      mix pesque.config template          # the example file, on stdout
      mix pesque.config template --out PATH

  Neither runs a boot: validate reads the file and the environment the way
  the server will at boot, and template prints the example file the settings
  table generates.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run_without_boot(["config" | argv])
end
