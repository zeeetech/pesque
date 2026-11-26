defmodule Pesque.StorageTest do
  use ExUnit.Case, async: false

  alias Pesque.Storage

  test "init tightens the data directory to 0700" do
    data_dir = Pesque.data_dir()
    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o755)

    assert :ok = Storage.init!()
    assert %File.Stat{mode: mode} = File.stat!(data_dir)
    assert Bitwise.band(mode, 0o777) == 0o700
  end
end
