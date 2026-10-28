defmodule Pesque.Cli.Restore do
  @moduledoc """
  Restores a backup archive over the data directory. Cold: the driver stops
  the service first; the verb refuses while the database is locked, and the
  swap leaves the previous state in `.old` names if anything stops it.

  `--dry-run` reads the archive's manifest and prints what the swap would
  move, and changes nothing.
  """

  use Gettext, backend: PesqueWeb.Gettext

  alias Pesque.Backup
  alias Pesque.Cli.Input

  @usage """
  usage: pesque restore (--archive PATH | PATH) [--dry-run]

  Restores over the data directory this one-off opened. The service must be
  stopped. --dry-run reads the archive and prints what would move, touching
  nothing.
  """

  def run(argv) do
    with {:ok, opts, args} <-
           Input.options(argv, [archive: :string, dry_run: :boolean], @usage, true),
         {:ok, archive} <- archive(opts[:archive], args),
         {:ok, inspection} <- Backup.inspect_archive(archive) do
      print_inspection(Pesque.data_dir(), inspection, opts[:dry_run])

      if opts[:dry_run] do
        :ok
      else
        restore(archive)
      end
    end
  end

  defp restore(archive) do
    case Backup.restore(Pesque.data_dir(), archive) do
      :ok ->
        IO.puts(
          "restored #{archive} into #{Pesque.data_dir()}; verify the service is healthy before use"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The dry run's whole answer, and the real run's before-picture. The
  # manifest itself is not listed among the entries: it is the archive's own
  # metadata, verified and then left with the staging directory, and its
  # contents are the first lines of this block. Field labels are plain
  # literals (names, not sentences), like every other report's.
  defp print_inspection(data_dir, %{manifest: manifest, entries: entries}, dry_run) do
    if dry_run, do: IO.puts(gettext("dry run: nothing has been restored"))

    field("version", manifest_value(manifest, "version"))
    field("created at", manifest_value(manifest, "created_at"))
    field("pesque version", manifest_value(manifest, "pesque_version"))

    Enum.each(entries -- ["manifest.json"], fn name ->
      IO.puts("    #{name} -> #{Path.join(data_dir, name)}")
    end)

    IO.puts(gettext("if anything stops the swap, the previous state is left in the .old files"))
  end

  # The label column, as account show prints it.
  @field_width 17

  defp field(label, value), do: IO.puts("  " <> String.pad_trailing(label, @field_width) <> value)

  # Manifest values arrive JSON-decoded, so a version is an integer and a
  # stamp a string; an archive that names neither has already been refused.
  defp manifest_value(manifest, key) do
    case Map.fetch(manifest, key) do
      {:ok, value} -> to_string(value)
      :error -> "-"
    end
  end

  defp archive(archive, []) when is_binary(archive), do: {:ok, archive}

  defp archive(nil, [archive]) when is_binary(archive), do: {:ok, archive}

  defp archive(nil, []), do: {:usage, "an archive is required\n\n" <> @usage}

  # The usage offers exactly one source, (--archive PATH | PATH). Both given
  # is not a silent preference but an ambiguity, and so is more than one
  # positional: both are usage.
  defp archive(_archive, _args), do: {:usage, @usage}
end
