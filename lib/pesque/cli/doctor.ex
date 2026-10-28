defmodule Pesque.Cli.Doctor do
  @moduledoc """
  The federation preflight, run with the endpoint down: the release-side half
  of `pesque doctor`.
  """

  alias Pesque.Cli.Input
  alias Pesque.Cli.Runtime

  @usage "usage: pesque doctor"

  def run(argv) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Runtime.start() do
      case Pesque.Doctor.run() do
        :ok -> :ok
        :error -> {:error, :doctor_failed}
      end
    end
  end
end
