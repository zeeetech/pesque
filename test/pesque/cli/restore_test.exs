defmodule Pesque.Cli.RestoreTest do
  @moduledoc """
  The restore verb's dry run: it reads the archive's manifest and prints what
  the swap would move, and the data directory it points at comes back exactly
  as it went in. The locale is pinned and the assertions read the English
  msgids, as in the other CLI tests; the verb is called as `Restore.run/1`
  so the entry locale resolution cannot override the pin.
  """

  use ExUnit.Case, async: false

  alias Pesque.Backup
  alias Pesque.Cli.Restore

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  test "the dry run prints the manifest, the entries and their targets, and changes nothing" do
    archive = valid_archive()
    data_dir = Pesque.data_dir()
    before = File.ls!(data_dir)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Restore.run(["--dry-run", "--archive", archive])
      end)

    assert output =~ "dry run: nothing has been restored"
    assert output =~ "version"
    assert output =~ "created at"
    assert output =~ Pesque.version()

    assert output =~ "pesque.db -> #{Path.join(data_dir, "pesque.db")}"
    assert output =~ "server.secret -> #{Path.join(data_dir, "server.secret")}"
    assert output =~ "keys/signing.key -> #{Path.join(data_dir, "keys/signing.key")}"

    assert output =~ "if anything stops the swap, the previous state is left in the .old files"

    # Read-only: the data directory this verb points at came back as it went
    # in, and no staging directory was left behind.
    assert File.ls!(data_dir) == before
    assert Path.wildcard(Path.join(data_dir, ".pesque-restore-*")) == []
  end

  test "the dry run refuses an archive that is not a pesque backup" do
    # The manifest is the first thing read; an archive without one is
    # refused the same way the restore would refuse it.
    root = fresh_dir()
    File.write!(Path.join(root, "pesque.db"), "bytes")
    archive = tar(root, ["pesque.db"])

    assert {:error, {:bad_archive, :no_manifest}} =
             Restore.run(["--dry-run", "--archive", archive])
  end

  test "the dry run refuses an archive missing a required entry" do
    root = fresh_dir()
    manifest = %{"format" => "pesque-backup", "version" => 1}
    File.write!(Path.join(root, "manifest.json"), JSON.encode!(manifest))
    File.write!(Path.join(root, "pesque.db"), "bytes")

    archive = tar(root, ["manifest.json", "pesque.db"])

    assert {:error, {:missing_entry, _name}} = Restore.run(["--dry-run", "--archive", archive])
  end

  test "the dry run refuses an archive whose version it does not know" do
    root = fresh_dir()
    manifest = %{"format" => "pesque-backup", "version" => 99}
    File.write!(Path.join(root, "manifest.json"), JSON.encode!(manifest))
    File.write!(Path.join(root, "pesque.db"), "bytes")

    archive = tar(root, ["manifest.json", "pesque.db"])

    assert {:error, {:unsupported_backup_version, 99}} =
             Restore.run(["--dry-run", "--archive", archive])
  end

  test "the dry run refuses bytes that are not a tar at all" do
    path = Path.join(fresh_dir(), "garbage.tar.gz")
    File.write!(path, "not a tar")

    assert {:error, {:bad_archive, _reason}} = Restore.run(["--dry-run", "--archive", path])
  end

  test "the dry run does not request an operator application boot" do
    archive = valid_archive()
    previous = Application.get_env(:pesque, :operator_boot)
    Application.delete_env(:pesque, :operator_boot)
    on_exit(fn -> restore_operator_boot(previous) end)

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Restore.run(["--dry-run", "--archive", archive])
    end)

    assert Application.get_env(:pesque, :operator_boot) == nil
  end

  # An archive the real writer made, so the entries the dry run lists are the
  # ones a real restore installs. The source is a throwaway data directory of
  # its own: the verb points at Pesque.data_dir() and the dry run must never
  # write there, so nothing here touches it.
  defp valid_archive do
    source = fresh_dir()
    File.mkdir_p!(Path.join(source, "keys"))
    File.mkdir_p!(Path.join(source, "blobs"))
    File.write!(Path.join(source, "server.secret"), "secret-1234")
    File.write!(Path.join([source, "keys", "signing.key"]), "key-bytes")

    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(source, "pesque.db"))
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE things (value TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, archive} = Backup.create(source, fresh_dir())
    archive
  end

  # The files are written by the caller; this only tars what is there.
  defp tar(root, names) do
    archive = Path.join(root, "archive.tar.gz")

    paths =
      for name <- names do
        {String.to_charlist(name), String.to_charlist(Path.join(root, name))}
      end

    :ok = :erl_tar.create(String.to_charlist(archive), paths, [:compressed])
    archive
  end

  defp fresh_dir do
    dir = Path.join(System.tmp_dir!(), "pesque-restore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp restore_operator_boot(nil), do: Application.delete_env(:pesque, :operator_boot)
  defp restore_operator_boot(value), do: Application.put_env(:pesque, :operator_boot, value)
end
