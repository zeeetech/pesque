defmodule Mix.Tasks.Pesque.Invite do
  @shortdoc "Creates invite codes for closed registration"

  @moduledoc """
  Mints invite codes, the same code `bin/pesque invite create` runs.

      mix pesque.invite create [--count N] [--uses N] [--for DID]
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["invite" | argv])
end
