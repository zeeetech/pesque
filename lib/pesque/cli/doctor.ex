defmodule Pesque.Cli.Doctor do
  @moduledoc """
  The federation preflight, run with the endpoint down: the release-side half
  of `pesque doctor`.
  """

  alias Pesque.Cli.Input
  alias Pesque.Release

  @usage "usage: pesque doctor"

  def run(argv) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Release.boot!() do
      case Pesque.Doctor.run() do
        :ok -> :ok
        :error -> {:error, :doctor_failed}
      end
    end
  end
end
