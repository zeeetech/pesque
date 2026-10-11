defmodule Pesque.RepoStore.ListUsersTest do
  @moduledoc """
  The operator's account list: did, handle, email and when (if ever) the
  account was deactivated. The timestamp is stamped by deactivate_account and
  cleared by activate_account, so an active account never carries a time it
  was no longer deactivated for.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.RepoStore

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)

    handle = "list" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  test "an active account answers with no deactivation time", %{user: user} do
    assert [%{did: did, handle: handle, email: "alice@localhost", deactivated_at: nil}] =
             RepoStore.list_users()

    assert did == user.did
    assert handle == user.handle
  end

  test "deactivation is stamped and activation clears it", %{user: user} do
    assert {:ok, _did} = Accounts.deactivate_account(user)

    assert [%{deactivated_at: deactivated_at}] = RepoStore.list_users()
    assert %DateTime{} = deactivated_at
    assert DateTime.compare(deactivated_at, DateTime.utc_now()) == :lt

    assert {:ok, _did} = Accounts.activate_account(user)

    assert [%{deactivated_at: nil}] = RepoStore.list_users()
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
