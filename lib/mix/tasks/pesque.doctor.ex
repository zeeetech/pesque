defmodule Mix.Tasks.Pesque.Doctor do
  @shortdoc "Checks whether this server is reachable and resolvable from outside."

  @moduledoc """
  Runs the federation preflight: configuration, DNS, describeServer, the DID
  document and handle resolution.

      mix pesque.doctor

  The installation guide's verify list, run for you. Each check answers ok,
  warn or fail, and a fail exits non-zero, so this works as a deploy gate.
  Read-only.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["doctor" | argv])
end
