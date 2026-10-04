defmodule Pesque.AccountIdentifierTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Did
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
  end

  # The collision is reachable unauthenticated: the string names one account
  # by handle and another by email, and login has to answer for it instead of
  # raising. The rows are inserted directly because create_account/3 refuses
  # to make them, which is the point of the refusal.
  test "a string that is one account's handle and another's email does not raise" do
    victim = insert_account("victim")
    other = insert_account("other")
    insert_account("impostor", victim.handle)

    assert {:ok, %User{did: did, handle: handle}} =
             Accounts.verify_login(victim.handle, @password)

    assert did == victim.did
    assert handle == victim.handle
    refute did == other.did

    assert :error = Accounts.verify_login(victim.handle, "wrong-password")

    for _ <- 1..3 do
      assert {:ok, %User{did: ^did}} = Accounts.verify_login(victim.handle, @password)
    end
  end

  test "an email equal to an existing handle is refused" do
    victim = insert_account("victim")
    before = key_files()

    assert {:error, :email_taken} =
             Accounts.create_account(unique("alice") <> ".localhost", victim.handle, @password)

    assert key_files() == before
  end

  test "a handle equal to an existing email is refused" do
    # An email that is also a syntactically valid handle, which is the only
    # way the reverse direction is reachable through create_account/3.
    handle = unique("collide") <> ".localhost"
    insert_account("holder", handle)
    before = key_files()

    assert {:error, :handle_not_available} =
             Accounts.create_account(handle, unique("a") <> "@localhost", @password)

    assert key_files() == before
  end

  test "the operator task refuses both directions" do
    victim = insert_account("victim")
    handle = unique("collide") <> ".localhost"
    insert_account("holder", handle)
    before = key_files()

    email_error =
      assert_raise Mix.Error, fn ->
        run_task(["--handle", unique("alice") <> ".localhost", "--email", victim.handle])
      end

    assert Exception.message(email_error) =~ "could not create account: :email_taken"

    handle_error =
      assert_raise Mix.Error, fn ->
        run_task(["--handle", handle, "--email", unique("a") <> "@localhost"])
      end

    assert Exception.message(handle_error) =~ "could not create account: :handle_not_available"
    assert key_files() == before
  end

  defp run_task(args) do
    Mix.Tasks.Pesque.CreateAccount.run(args ++ ["--password", @password])
  end

  defp insert_account(name, email \\ nil) do
    username = unique(name)

    user =
      Repo.insert!(
        User.changeset(%{
          did: Did.did_for_username(:path_multi, host(), username),
          handle: username <> ".localhost",
          username: username,
          pubkey_multibase: "z" <> username,
          email: email || unique("mail") <> "@localhost",
          password_hash: Argon2.hash_pwd_salt(@password)
        })
      )

    on_exit(fn -> Repo.delete_all(from u in User, where: u.id == ^user.id) end)
    user
  end

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  defp host, do: Did.did_host(Pesque.hostname(), Pesque.port())

  defp key_files, do: Pesque.Storage.keys_dir() |> File.ls!() |> Enum.sort()

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
