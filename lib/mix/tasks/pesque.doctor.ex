defmodule Mix.Tasks.Pesque.Doctor do
  @shortdoc "Checks whether this server is reachable and resolvable from outside."

  @moduledoc """
  Runs the federation preflight: configuration, DNS, describeServer, the DID
  document and handle resolution.

      mix pesque.doctor

  These are the checks in the installation guide's verify list, run for you.
  Each answers ok, warn or fail, and a fail exits non-zero, so this works as a
  deploy gate. Read-only: nothing here writes.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.config")

    # No endpoint: the checks read the server's identity and fetch its public
    # URLs, they never answer a request.
    Application.put_env(:pesque, :serve, false)

    Mix.Task.run("app.start")

    if Pesque.Doctor.run() == :error do
      Mix.raise("doctor found problems")
    end
  end
end
