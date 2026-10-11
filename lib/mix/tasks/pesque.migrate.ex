defmodule Mix.Tasks.Pesque.Migrate do
  @shortdoc "Moves an existing ATProto account onto this server."

  @moduledoc """
  Moves an existing ATProto account (for example a did:plc account on
  bsky.social) onto this server, automating the scriptable half of
  docs/guides/migration.md.

      mix pesque.migrate --old-pds https://bsky.social --handle alice.example.com \
        --email alice@example.com --password-env PESQUE_PASSWORD

  The password (the old PDS account password, not an app password) comes
  from `--password-env`, `MIGRATE_PASSWORD`, or a no-echo prompt; `--password
  VALUE` is the dev-convenience spelling of the first, for throwaway local
  runs, and outranks `--password-env`. The value never reaches the verb
  layer as an argument: this task sets it as the environment variable the
  verb reads and dispatches an argv with no password in it.

  The move stops at the identity step for a code the account holder receives by
  email; pass `--plc-token` (or set `MIGRATE_PLC_TOKEN`) on the second run.

  Runs with the endpoint not serving, so it works against a data directory the
  live server already has open instead of failing on the port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv), do: Mix.Pesque.run_with_password(["migrate" | argv], "MIGRATE_PASSWORD")
end
