defmodule Pesque.Mix.ReleaseSteps do
  @moduledoc """
  Custom release steps, run by `mix release` after `:assemble`.

  The release is the single source of truth for the operations API (D1): the
  stock `bin/pesque` stays byte-identical as `bin/pesque.core`, and the
  wrapper installed at `bin/pesque` dispatches the verb commands through one
  fixed eval into `Pesque.Cli.main()`. Every other call runs the stock
  script, so `start`, `daemon`, `eval`, `version` and the rest keep working
  exactly as the release generated them.
  """

  @doc """
  The `cli` step: copy the generated script to `pesque.core` and install the
  wrapper. `version` is deliberately not a verb (the stock `version` command
  boots no VM), and Windows keeps the stock `pesque.bat`.
  """
  def cli(%Mix.Release{} = release) do
    bin = Path.join(release.path, "bin/pesque")
    core = Path.join(release.path, "bin/pesque.core")

    File.cp!(bin, core)
    File.write!(bin, wrapper())
    File.chmod!(bin, 0o755)

    release
  end

  @doc """
  The wrapper installed at `bin/pesque`. The verb list is `Pesque.Cli.verbs/0`,
  so a verb added there is dispatched here in the same change.
  """
  def wrapper do
    verbs = Enum.join(Pesque.Cli.verbs(), "|")

    """
    #!/bin/sh
    set -e
    CORE="$(dirname "$0")/pesque.core"
    case "${1:-}" in
      #{verbs})
        exec "$CORE" eval 'Pesque.Cli.main()' "$@";;
      *) exec "$CORE" "$@";;
    esac
    """
  end
end
