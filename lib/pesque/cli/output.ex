defmodule Pesque.Cli.Output do
  @moduledoc """
  The machine channel of the read verbs: one JSON object on stdout.

  stdout is data, stderr is prose, so a `--json` run prints the payload and
  nothing else: a verb that fails answers `{:error, reason}` before anything
  is printed, `main/0` puts the prose on stderr, and the exit code carries
  the failure. stdout stays empty for the script that is parsing it.

  The shapes are a published surface a script can grow old with: one
  top-level object keyed by the noun (`%{"accounts" => [...]}`), field names
  from the storage vocabulary (`did`, `handle`, `deactivated_at`), and
  timestamps ISO-8601 or null, never a dash standing in for absence.
  """

  @doc "Encodes `payload` as one JSON line on stdout."
  @spec json(term()) :: :ok
  def json(payload) do
    payload
    |> JSON.encode!()
    |> IO.puts()
  end
end
