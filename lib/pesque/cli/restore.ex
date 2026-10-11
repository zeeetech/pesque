defmodule Pesque.Cli.Restore do
  @moduledoc """
  Restores a backup archive over the data directory. Cold: the driver stops
  the service first; the verb refuses while the database is locked, and the
  swap leaves the previous state in `.old` names if anything stops it.
  """

  alias Pesque.Backup
  alias Pesque.Cli.Input
  alias Pesque.Release

  @usage """
  usage: pesque restore (--archive PATH | PATH)

  Restores over the data directory this one-off opened. The service must be
  stopped.
  """

  def run(argv) do
    with {:ok, opts, args} <- Input.options(argv, [archive: :string], @usage, true),
         {:ok, archive} <- archive(opts[:archive] || List.first(args)),
         :ok <- Release.boot!() do
      case Backup.restore(Pesque.data_dir(), archive) do
        :ok ->
          IO.puts("restored #{archive} into #{Pesque.data_dir()}; start the server again")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp archive(nil), do: {:usage, "an archive is required\n\n" <> @usage}

  defp archive(archive), do: {:ok, archive}
end
