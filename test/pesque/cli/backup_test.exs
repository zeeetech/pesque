defmodule Pesque.Cli.BackupTest do
  @moduledoc """
  The backup verb, and the one thing it must not do: boot the application.

  The archive is the database's own snapshot plus the files beside it, so the
  verb reads through no Repo and starts no application. The data directory is
  built at the file level and pointed at through the configuration, the same
  way the operator's provider-installed `data_dir` is, so nothing here takes
  the suite's own sandboxed Repo into the verb.
  """

  use ExUnit.Case, async: false

  alias Pesque.Cli.Backup

  setup do
    dir = fresh_dir("pesque-cli-backup-src")
    File.mkdir_p!(Path.join(dir, "keys"))
    File.mkdir_p!(Path.join(dir, "blobs"))
    File.write!(Path.join(dir, "server.secret"), "secret-1234")
    File.write!(Path.join([dir, "keys", "signing.key"]), "key-bytes")

    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(dir, "pesque.db"))
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE things (value TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)

    point_data_dir_at(dir)

    %{dir: dir, out: fresh_dir("pesque-cli-backup-out")}
  end

  test "writes the archive under --out from the configured data directory", %{
    dir: dir,
    out: out
  } do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Backup.run(["--out", out])
      end)

    assert output =~ "wrote "

    [archive] = Path.wildcard(Path.join(out, "pesque-backup-*.tar.gz"))
    assert output =~ archive
    assert File.read!(Path.join(dir, "server.secret")) == "secret-1234"

    {:ok, entries} = :erl_tar.table(String.to_charlist(archive), [:compressed])
    names = Enum.map(entries, &to_string/1)

    for entry <- ["manifest.json", "pesque.db", "server.secret", "keys/signing.key"] do
      assert entry in names, "the archive is missing #{entry}"
    end
  end

  # The boot the verb must not request: Runtime.start/0 sets this flag, and
  # the flag is what pulls the Repo, the registries and the endpoint into the
  # supervisor. Its absence is the cold run.
  test "does not request an operator application boot", %{out: out} do
    previous = Application.get_env(:pesque, :operator_boot)
    Application.delete_env(:pesque, :operator_boot)
    on_exit(fn -> restore_operator_boot(previous) end)

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok = Backup.run(["--out", out])
    end)

    assert Application.get_env(:pesque, :operator_boot) == nil
  end

  test "an unknown option is usage, before any boot" do
    previous = Application.get_env(:pesque, :operator_boot)
    Application.delete_env(:pesque, :operator_boot)
    on_exit(fn -> restore_operator_boot(previous) end)

    assert {:usage, text} = Backup.run(["--wat"])

    assert text =~ "unknown option: --wat"
    assert text =~ "usage: pesque backup"
    assert Application.get_env(:pesque, :operator_boot) == nil
  end

  # The data directory is the operator's, installed through the provider's
  # configuration; the verb only reads it. The test swaps it for one of its
  # own and puts the configured one back.
  defp point_data_dir_at(dir) do
    previous = Application.get_env(:pesque, :data_dir)
    Application.put_env(:pesque, :data_dir, dir)
    on_exit(fn -> Application.put_env(:pesque, :data_dir, previous) end)
  end

  defp fresh_dir(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp restore_operator_boot(nil), do: Application.delete_env(:pesque, :operator_boot)
  defp restore_operator_boot(value), do: Application.put_env(:pesque, :operator_boot, value)
end
