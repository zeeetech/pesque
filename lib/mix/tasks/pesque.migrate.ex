defmodule Mix.Tasks.Pesque.Migrate do
  @shortdoc "Moves an existing ATProto account onto this server."

  @moduledoc """
  Moves an existing ATProto account onto this server, automating the
  scriptable half of docs/guides/migration.md.

      mix pesque.migrate --old-pds https://bsky.social --handle alice.example.com \
        --email alice@example.com

  The password (the old PDS account password, not an app password) comes
  from a no-echo prompt, or from a line on stdin so it can be piped. The move
  stops at the identity step for a code the account holder receives by email;
  pass `--plc-token` (or set `MIGRATE_PLC_TOKEN`) on the second run. Runs with
  the endpoint not serving.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run(["migrate" | argv])
end
