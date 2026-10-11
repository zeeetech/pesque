defmodule Pesque.BackupTest do
  @moduledoc """
  Backup and restore over a data directory of its own, built at the file
  level: the suite's Repo runs in the sandbox, whose open transaction is
  invisible to a snapshot taken through a connection of its own.
  """

  use ExUnit.Case, async: false

  alias Pesque.Backup

  setup do
    dir = fresh_dir("pesque-backup-src")
    File.mkdir_p!(Path.join(dir, "keys"))
    File.mkdir_p!(Path.join(dir, "blobs"))
    File.write!(Path.join(dir, "server.secret"), "secret-1234")
    File.write!(Path.join([dir, "keys", "signing.key"]), "key-bytes")

    File.write!(
      Path.join(dir, "server.identity.json"),
      ~s({"did": "did:plc:test", "operation": {}})
    )

    # One row, so the round trip can prove the database came back.
    {:ok, conn} = Exqlite.Sqlite3.open(db_path(dir))
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE things (value TEXT)")
    {:ok, insert} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO things VALUES (?)")
    :ok = Exqlite.Sqlite3.bind(insert, ["kept"])
    :done = Exqlite.Sqlite3.step(conn, insert)
    :ok = Exqlite.Sqlite3.close(conn)

    out = fresh_dir("pesque-backup-out")

    %{dir: dir, out: out}
  end

  test "create writes a gzipped tar carrying the manifest, db, keys, blobs and secret", %{
    dir: dir,
    out: out
  } do
    assert {:ok, archive} = Backup.create(dir, out)
    assert String.ends_with?(archive, ".tar.gz")

    {:ok, names} = :erl_tar.table(String.to_charlist(archive), [:compressed])
    names = Enum.map(names, &to_string/1)

    for entry <- ["manifest.json", "pesque.db", "server.secret", "keys/signing.key"] do
      assert entry in names, "the archive is missing #{entry}"
    end
  end

  test "create refuses a data directory a server never booted in", %{out: out} do
    empty = fresh_dir("pesque-backup-empty")

    assert {:error, {:missing_data_dir_entries, missing}} = Backup.create(empty, out)
    assert "pesque.db" in missing
    assert "server.secret" in missing
  end

  test "restore puts the archived database, secret and keys back in a fresh data dir", %{
    dir: dir,
    out: out
  } do
    {:ok, archive} = Backup.create(dir, out)

    target = fresh_dir("pesque-backup-dst")
    assert :ok = Backup.restore(target, archive)

    assert File.read!(Path.join(target, "server.secret")) == "secret-1234"
    assert File.read!(Path.join([target, "keys", "signing.key"])) == "key-bytes"
    assert File.exists?(Path.join(target, "server.identity.json"))

    assert {:row, ["kept"]} = query_value(target)

    # A completed swap cleans up after itself.
    refute File.exists?(Path.join(target, "pesque.db.old"))
    assert Path.wildcard(Path.join(target, ".pesque-restore-*")) == []
  end

  test "a stale WAL moves with the old database and does not survive the restore", %{
    dir: dir,
    out: out
  } do
    {:ok, archive} = Backup.create(dir, out)

    target = fresh_dir("pesque-backup-wal")
    File.cp!(db_path(dir), Path.join(target, "pesque.db"))
    File.write!(Path.join(target, "pesque.db-wal"), "stale writes")

    assert :ok = Backup.restore(target, archive)

    refute File.exists?(Path.join(target, "pesque.db-wal"))
    assert {:row, ["kept"]} = query_value(target)
  end

  # The identity file is an optional entry: a server that never minted a PLC
  # identity has none to back up, and the restore still removes the running
  # one, so the restored data directory is exactly the archive's.
  test "an archive without the optional PLC identity removes the running one", %{out: out} do
    source = fresh_dir("pesque-backup-noid")
    File.mkdir_p!(Path.join(source, "keys"))
    File.mkdir_p!(Path.join(source, "blobs"))
    File.write!(Path.join(source, "server.secret"), "secret-noid")

    {:ok, conn} = Exqlite.Sqlite3.open(db_path(source))
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE things (value TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, archive} = Backup.create(source, out)

    target = fresh_dir("pesque-backup-noid-dst")
    File.write!(Path.join(target, "server.identity.json"), "{}")

    assert :ok = Backup.restore(target, archive)
    refute File.exists?(Path.join(target, "server.identity.json"))
    assert File.read!(Path.join(target, "server.secret")) == "secret-noid"
    refute File.exists?(Path.join(target, "pesque.db.old"))
  end

  test "restore refuses an archive whose manifest version it does not know", %{
    dir: dir,
    out: out
  } do
    {:ok, _archive} = Backup.create(dir, out)
    patched = archive_with_version(99)

    target = fresh_dir("pesque-backup-refuse")
    assert {:error, {:unsupported_backup_version, 99}} = Backup.restore(target, patched)

    # Nothing moved.
    refute File.exists?(Path.join(target, "pesque.db"))
    assert Path.wildcard(Path.join(target, ".pesque-restore-*")) == []
  end

  test "restore refuses while another connection holds the write lock", %{dir: dir, out: out} do
    {:ok, archive} = Backup.create(dir, out)

    {:ok, conn} = Exqlite.Sqlite3.open(db_path(dir))
    {:ok, lock} = Exqlite.Sqlite3.prepare(conn, "BEGIN IMMEDIATE")
    :ok = Exqlite.Sqlite3.bind(lock, [])
    :done = Exqlite.Sqlite3.step(conn, lock)

    assert {:error, :locked} = Backup.restore(dir, archive)

    :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
    :ok = Exqlite.Sqlite3.close(conn)
  end

  # install/2 is the cold swap restore ends with. Standing in for the crash:
  # a staged directory missing one entry stops the swap after earlier entries
  # already moved the current files aside, the same state and recovery a
  # crash mid-swap leaves.
  test "a swap that stops partway leaves the previous state in .old", %{dir: dir} do
    target = fresh_dir("pesque-backup-swap")
    File.cp!(db_path(dir), Path.join(target, "pesque.db"))
    File.write!(Path.join(target, "server.secret"), "secret-1234")
    old_bytes = File.read!(Path.join(target, "pesque.db"))

    staged = fresh_dir("pesque-backup-staged")
    File.cp!(db_path(dir), Path.join(staged, "pesque.db"))

    assert {:error, {:missing_staged, "server.secret"}} = Backup.install(target, staged)

    assert File.read!(Path.join(target, "pesque.db.old")) == old_bytes
    assert File.read!(Path.join(target, "server.secret.old")) == "secret-1234"
  end

  defp db_path(dir), do: Path.join(dir, "pesque.db")

  # Registered for cleanup where it is created, so no test leaves a
  # pesque-backup-* directory behind in the tmp dir.
  defp fresh_dir(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp query_value(dir) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path(dir), mode: :readonly)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT value FROM things")
    row = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.close(conn)
    row
  end

  # An archive this server did not write: the manifest names a version the
  # verifier must refuse before anything moves.
  defp archive_with_version(version) do
    root = fresh_dir("pesque-backup-bad")
    File.mkdir_p!(Path.join(root, "keys"))
    File.mkdir_p!(Path.join(root, "blobs"))
    File.write!(Path.join(root, "pesque.db"), "not really a database")
    File.write!(Path.join(root, "server.secret"), "secret")
    File.write!(Path.join(root, "server.identity.json"), "{}")

    manifest = %{"format" => "pesque-backup", "version" => version}
    File.write!(Path.join(root, "manifest.json"), JSON.encode!(manifest))

    archive =
      Path.join(
        System.tmp_dir!(),
        "pesque-backup-bad-#{version}-#{System.unique_integer([:positive])}.tar.gz"
      )

    entries =
      for name <- ["manifest.json", "pesque.db", "server.secret", "server.identity.json"] do
        {String.to_charlist(name), String.to_charlist(Path.join(root, name))}
      end

    :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])
    on_exit(fn -> File.rm(archive) end)
    archive
  end
end
