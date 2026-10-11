defmodule Pesque.Backup do
  @moduledoc """
  A live-safe backup of the data directory, and a cold restore over it.

  Backup (D5) snapshots the database with `VACUUM INTO` first, so the archive
  holds the committed state at one instant whether the server is running or
  not, then tars the keys, the blobs and the secret straight out of the data
  directory. That is safe on a live server because an upload writes the file
  before the row that serves it: the worst a race with a running upload can
  do is put an orphan file in the archive, never a row whose bytes are
  missing. The invariant is a property of `Pesque.Blob.upload/3` and is
  regression-tested as one.

  Restore is cold: the driver stops the service first, and the verb refuses
  while another process holds the database's write lock. Before anything
  moves, the archive is extracted into a staging directory *inside* the data
  directory (the swap is atomic per entry only when staged and target share
  a filesystem) and verified against its manifest. The swap then moves every
  current file to `<name>.old` before its replacement takes its name, so a
  crash mid-swap leaves the previous state next to the new one: rename the
  `.old` files back, or run restore again. A completed swap removes them;
  the archive itself is the way back.
  """

  alias Pesque.RepoStore

  @manifest_format "pesque-backup"
  @manifest_version 1

  # What a booted server always has, split by kind only because the tar
  # carries the files and the directories the same way.
  @files ["pesque.db", "server.secret"]
  @dirs ["keys", "blobs"]
  # The PLC identity is written only under PDS_IDENTITY=plc.
  @optional ["server.identity.json"]

  # The order the swap runs in: one entry at a time, each moved aside before
  # its replacement lands. The last one is optional: an archive from a server
  # that never minted a PLC identity carries none, and the swap still removes
  # the running one, so the restored data directory holds exactly what the
  # archive carried.
  @required_entries ["pesque.db", "server.secret", "keys", "blobs"]
  @optional_entries ["server.identity.json"]
  @swap_order @required_entries ++ @optional_entries

  # WAL sidecars belong to the database they were opened with. Leaving a
  # stale -wal beside the restored file would have SQLite replay the old
  # writes onto the new database, so they move with the old db, under the
  # name the old db would look for if it is ever renamed back.
  @db_sidecars ["pesque.db-wal", "pesque.db-shm"]

  @doc """
  Creates `pesque-backup-<stamp>.tar.gz` in `out_dir` and answers its path.

  Refuses a data directory that is missing a piece every booted server has:
  an archive that looks complete and restores into a server that cannot boot
  is worse than a refused backup.
  """
  def create(data_dir, out_dir) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    archive = Path.join(out_dir, "pesque-backup-#{stamp}.tar.gz")
    staging = Path.join(System.tmp_dir!(), "pesque-backup-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(out_dir),
           :ok <- required(data_dir),
           :ok <- File.mkdir_p(staging),
           :ok <-
             RepoStore.vacuum_into(
               Path.join(data_dir, "pesque.db"),
               Path.join(staging, "pesque.db")
             ),
           :ok <- write_manifest(staging) do
        tar(staging, data_dir, archive)
      end
    after
      _ = File.rm_rf(staging)
    end
  end

  @doc """
  Verifies `archive` and swaps it into `data_dir` cold.

  Refuses an archive whose manifest names a format or version this server
  does not know, and refuses to touch a database another process holds the
  write lock on. On success the data directory holds exactly what the
  archive carried; on any refusal nothing has moved.
  """
  def restore(data_dir, archive) do
    staged = Path.join(data_dir, ".pesque-restore-#{System.unique_integer([:positive])}")

    try do
      with :ok <- check_lock(Path.join(data_dir, "pesque.db")),
           :ok <- extract(archive, staged),
           :ok <- verify(staged) do
        case install(data_dir, staged) do
          :ok ->
            clear_old(data_dir)
            :ok

          {:error, _reason} = error ->
            error
        end
      end
    after
      _ = File.rm_rf(staged)
    end
  end

  @doc """
  The cold swap restore ends with: for every entry, the current file moves to
  `<name>.old` first and the staged one takes its name.

  Public because the failure it leaves behind is part of the contract: a
  name with nothing staged stops the swap with the `.old` files already
  made, which is the same state a crash mid-swap leaves, and the same
  recovery. The WAL sidecars of the old database move with it, so a stale
  `-wal` is never replayed onto the restored file.
  """
  def install(data_dir, staged_dir) do
    Enum.reduce_while(@swap_order, :ok, fn
      _name, {:error, _reason} = error -> {:halt, error}
      name, :ok -> {:cont, swap_one(data_dir, staged_dir, name)}
    end)
  end

  # The pieces a booted server always has.
  defp required(data_dir) do
    case Enum.filter(@files ++ @dirs, &(not File.exists?(Path.join(data_dir, &1)))) do
      [] -> :ok
      missing -> {:error, {:missing_data_dir_entries, Enum.sort(missing)}}
    end
  end

  defp write_manifest(staging) do
    manifest = %{
      "format" => @manifest_format,
      "version" => @manifest_version,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "pesque_version" => Pesque.version()
    }

    File.write(Path.join(staging, "manifest.json"), JSON.encode!(manifest))
  end

  # Entries are named from the archive root whatever lives where on the host:
  # the manifest and the snapshot come from staging, the rest from the data
  # directory, so the big directories are read once and never copied.
  defp tar(staging, data_dir, archive) do
    entries =
      for {name, path} <-
            [
              {"manifest.json", Path.join(staging, "manifest.json")},
              {"pesque.db", Path.join(staging, "pesque.db")}
            ] ++
              data_dir_entries(data_dir) do
        {String.to_charlist(name), String.to_charlist(path)}
      end

    case :erl_tar.create(String.to_charlist(archive), entries, [:compressed]) do
      :ok -> {:ok, archive}
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp data_dir_entries(data_dir) do
    for name <- @files ++ @dirs ++ @optional,
        path = Path.join(data_dir, name),
        File.exists?(path),
        do: {name, path}
  end

  # A short wait, not a polite one: the driver has already stopped the
  # service, so a held lock means something is still writing and restore
  # must not race it. One second is enough to tell mid-write from stopped.
  @lock_wait_ms 1_000

  defp check_lock(db) do
    if File.exists?(db) do
      RepoStore.write_lock(db, @lock_wait_ms)
    else
      :ok
    end
  end

  # Extraction lands inside the data directory, where the swap can rename.
  defp extract(archive, staged) do
    with :ok <- File.mkdir_p(staged) do
      case :erl_tar.extract(String.to_charlist(archive), [
             :compressed,
             cwd: String.to_charlist(staged)
           ]) do
        :ok -> :ok
        {:error, reason} -> {:error, {:bad_archive, reason}}
      end
    end
  end

  # Everything a boot needs, before anything moves. The keys and blobs
  # directories may be empty, but they have to be there: restore replaces
  # the data directory's contents, it does not merge with what is running.
  defp verify(staged) do
    with {:ok, manifest} <- read_manifest(staged),
         :ok <- check_format(manifest),
         :ok <- check_version(manifest) do
      check_entries(staged)
    end
  end

  defp read_manifest(staged) do
    case File.read(Path.join(staged, "manifest.json")) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{} = manifest} -> {:ok, manifest}
          {:error, _reason} -> {:error, {:bad_archive, :manifest_not_json}}
        end

      {:error, _reason} ->
        {:error, {:bad_archive, :no_manifest}}
    end
  end

  defp check_format(%{"format" => @manifest_format}), do: :ok
  defp check_format(_manifest), do: {:error, {:bad_archive, :unknown_format}}

  defp check_version(%{"version" => @manifest_version}), do: :ok

  defp check_version(%{"version" => version}),
    do: {:error, {:unsupported_backup_version, version}}

  defp check_version(_manifest), do: {:error, {:bad_archive, :no_version}}

  defp check_entries(staged) do
    case Enum.filter(@required_entries, &(not File.exists?(Path.join(staged, &1)))) do
      [] -> :ok
      missing -> {:error, {:missing_entry, hd(Enum.sort(missing))}}
    end
  end

  defp swap_one(data_dir, staged_dir, "pesque.db") do
    current = Path.join(data_dir, "pesque.db")

    with :ok <- move_aside(current, current <> ".old"),
         :ok <- move_sidecars(data_dir) do
      promote(staged_dir, "pesque.db", current)
    end
  end

  defp swap_one(data_dir, staged_dir, name) do
    current = Path.join(data_dir, name)

    with :ok <- move_aside(current, current <> ".old") do
      cond do
        name in @optional_entries and not File.exists?(Path.join(staged_dir, name)) ->
          :ok

        true ->
          promote(staged_dir, name, current)
      end
    end
  end

  # Nothing current means nothing to keep: a restore into an empty data
  # directory makes no `.old`.
  defp move_aside(current, old) do
    case File.rename(current, old) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:swap_failed, Path.basename(current), reason}}
    end
  end

  defp move_sidecars(data_dir) do
    Enum.reduce_while(@db_sidecars, :ok, fn sidecar, :ok ->
      current = Path.join(data_dir, sidecar)
      old = Path.join(data_dir, old_name(sidecar))

      case File.rename(current, old) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:swap_failed, sidecar, reason}}}
      end
    end)
  end

  defp promote(staged_dir, name, current) do
    case File.rename(Path.join(staged_dir, name), current) do
      :ok -> :ok
      {:error, :enoent} -> {:error, {:missing_staged, name}}
      {:error, reason} -> {:error, {:swap_failed, name, reason}}
    end
  end

  # A completed swap leaves the previous state in the `.old` names; the
  # archive is the way back, so the copies go.
  defp clear_old(data_dir) do
    for name <- @swap_order, do: _ = File.rm_rf(Path.join(data_dir, name) <> ".old")
    for sidecar <- @db_sidecars, do: _ = File.rm(Path.join(data_dir, old_name(sidecar)))

    :ok
  end

  defp old_name("pesque.db" <> suffix), do: "pesque.db.old" <> suffix
end
