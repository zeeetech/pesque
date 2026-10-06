defmodule Pesque.Accounts.DeleteAccountTest do
  @moduledoc """
  The password check on the deletion path, called directly rather than over HTTP.

  What these pin is the answer delete_account/4 gives for each password, and
  where it stops. They do not observe the hash gate that sits behind the check:
  a permit is an internal counter and a timing property, so nothing on this path
  answers differently once the gate is taken. That the check goes through the
  gate is a claim about the source, and the argon2 gate test is where it is
  asserted.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    # path_multi so the account gets a handle: under conformant_single the
    # seeded server row has no handle and every account compares as taken.
    put_mode(:path_multi)

    handle = "delete" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  test "the wrong password answers invalid_password and the account stays", %{user: user} do
    assert Accounts.delete_account(user, user.did, "wrong", "token") ==
             {:error, :invalid_password}

    assert Accounts.get_user(user.did)
  end

  # Stops at the token rather than at the password, which is how a correct
  # password is shown to get past the check: the next clause in the chain is
  # what answers instead.
  test "the account's own password gets past the check and on to the token", %{user: user} do
    assert Accounts.delete_account(user, user.did, @password, "not-a-token") ==
             {:error, :invalid_token}
  end

  test "a did that is not the account's is refused before the password is read", %{user: user} do
    assert Accounts.delete_account(user, "did:plc:notthisone", @password, "token") ==
             {:error, :wrong_account_did}
  end

  # argon2 raises ArgumentError out of the NIF on anything that is not a string,
  # and deleteAccount is reachable without a rate limit, so a raise here is a
  # 500 an unauthenticated caller can ask for on demand.
  test "a non-binary password answers invalid_password instead of raising", %{user: user} do
    assert Accounts.delete_account(user, user.did, ["hunter2"], "token") ==
             {:error, :invalid_password}

    assert Accounts.delete_account(user, user.did, nil, "token") ==
             {:error, :invalid_password}

    assert Accounts.get_user(user.did)
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
