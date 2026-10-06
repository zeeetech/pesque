defmodule Pesque.Accounts.PasswordHashPlacementTest do
  @moduledoc """
  Where the password is hashed, and what it costs when it is wrong.

  SQLite has one writer. insert/5 opens a transaction, and an argon2 hash is
  tens of milliseconds holding tens of megabytes resident, so hashing inside it
  means every unrelated write on the server queues behind a registration. Under
  PDS_REGISTRATION=open that is an unauthenticated endpoint serialising the
  whole database.

  The second half is the cheaper one to state: a rejected invite code should not
  cost a hash. The code is claimed inside the transaction by design, so moving
  the hash out is also what makes a wrong code free.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.InviteCode
  alias Pesque.Accounts.User
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
  end

  # Reached from the open createAccount endpoint, and the shape that made the
  # status-code oracle: a non-string password used to raise out of
  # check_password/1's byte_size before it ever reached the NIF, so the clamp
  # at hash_password/1 was behind a second raise rather than the only one.
  test "a non-string password is a tuple, not a raise" do
    for password <- [[], %{"a" => 1}, 123, nil, true] do
      assert {:error, :password_too_short} =
               Accounts.create_account("bob.localhost", "bob@localhost", password)
    end

    assert Repo.aggregate(User, :count) == 0
  end

  test "an account is created with a usable password hash" do
    user = create("alice")

    assert user.password_hash =~ "$argon2id$"
    assert {:ok, %User{did: did}} = Accounts.verify_login(user.handle, @password)
    assert did == user.did
  end

  test "a wrong invite code costs no hash and spends no code" do
    before = Repo.aggregate(User, :count)

    assert {:error, :invalid_invite_code} =
             Accounts.create_account("bob.localhost", "bob@localhost", @password,
               invite_code: "notacode"
             )

    assert Repo.aggregate(User, :count) == before
    assert Repo.aggregate(InviteCode, :count) == 0
  end

  # The transaction still has to be able to roll the invite claim back, which
  # is the reason the code is spent there and the hash is not.
  test "a code spent on an insert that then failed is spendable again" do
    create("alice")
    code = mint()

    assert {:error, :email_taken} =
             Accounts.create_account("bob.localhost", "alice@localhost", @password,
               invite_code: code
             )

    assert %InviteCode{uses: 0, used_by: nil} = Repo.get_by(InviteCode, code: code)
  end

  # The hash being outside the transaction means it happens even when the
  # transaction is about to fail, so the failure path has to clean up after
  # itself. A leaked key file makes the next attempt at that handle fail on the
  # exclusive create.
  test "a failed create leaves no key file behind" do
    create("alice")
    before = key_files()

    assert {:error, :email_taken} =
             Accounts.create_account("bob.localhost", "alice@localhost", @password)

    create("bob")

    assert key_files() -- before == [Path.basename(Pesque.Keys.path(did_for("bob")))]
  end

  defp mint(use_count \\ 1) do
    {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, use_count)
    code
  end

  defp create(name) do
    {:ok, user} = Accounts.create_account(name <> ".localhost", name <> "@localhost", @password)
    user
  end

  defp did_for(username), do: Pesque.Did.did_for_username(:path_multi, host(), username)

  defp host, do: Pesque.Did.did_host(Pesque.hostname(), Pesque.port())

  defp key_files, do: File.ls!(Pesque.Storage.keys_dir())

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
