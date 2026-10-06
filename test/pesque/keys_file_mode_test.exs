defmodule Pesque.KeysFileModeTest do
  @moduledoc """
  The key file's mode, and what the window between create and chmod holds.

  The spec for this asked for the mode to be set on the open rather than by a
  chmod after it, so that a local process which opened the file between the two
  could not keep reading the key. That is not available: Erlang's file:open/2
  has no creation-mode option, `{:mode, 0o600}` is accepted and ignored, and
  the file lands on the umask. Verified on this machine by stat-ing a file
  created that way, not inferred.

  So the chmod stays and the assertion here is the one that can be made: the
  window holds an empty file, and keys_dir is 0700, so the path is not
  reachable by another user at all. If a future OTP honours a creation mode,
  the test that would want to change is the one asserting the open options.
  """

  use ExUnit.Case, async: true

  alias Pesque.Keys
  alias Pesque.Storage

  setup do
    did = "did:web:example.com:user:" <> uniq()
    on_exit(fn -> Keys.delete(did) end)
    %{did: did}
  end

  test "the key file is 0600", %{did: did} do
    {:ok, _key} = Keys.create_exclusive(did)

    assert %File.Stat{mode: mode} = File.stat!(Keys.path(did))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "the directory holding key files is 0700", %{did: did} do
    {:ok, _key} = Keys.create_exclusive(did)

    assert %File.Stat{mode: mode} = File.stat!(Storage.keys_dir())
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  # What the chmod ordering actually buys, stated as what is true rather than
  # what would be nicer. The window is real and this test can see it: the
  # poller catches the file at the umask mode, before write/1 chmods it. What
  # the ordering guarantees is that the window holds no key. A reader who
  # opened the file in that gap gets zero bytes, and after the chmod lands the
  # path is 0600 anyway. Closing the window entirely needs a creation mode that
  # open(2) honours, which the next test shows this OTP does not offer.
  test "the window between create and chmod holds no key bytes", %{did: did} do
    path = Keys.path(did)

    task =
      Task.async(fn ->
        # Catches the file the moment it appears, which is inside the window
        # create_exclusive/1 opens between :file.open and File.chmod.
        Stream.repeatedly(fn -> File.stat(path) end)
        |> Enum.find(fn
          {:ok, _stat} -> true
          {:error, _reason} -> false
        end)
      end)

    assert {:ok, _key} = Keys.create_exclusive(did)

    assert {:ok, %File.Stat{size: 0}} = Task.await(task, 5_000)

    # And once it is closed the file is 0600 and holds the key.
    assert %File.Stat{mode: mode, size: size} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert size > 0
  end

  # Documentation, in test form: the option the spec asks for is a no-op here.
  # If a future OTP makes it work, this fails and says what to change.
  test "file:open ignores a creation mode on this OTP" do
    path = Path.join(System.tmp_dir!(), "keys_mode_probe_#{uniq()}")

    {:ok, device} = :file.open(path, [:write, :exclusive, {:mode, 0o600}])
    :ok = :file.close(device)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) != 0o600

    File.rm(path)
  end

  defp uniq, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
