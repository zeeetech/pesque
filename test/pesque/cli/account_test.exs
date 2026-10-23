defmodule Pesque.Cli.AccountTest do
  @moduledoc """
  The account verbs this slice owns, at their own door: the list filters, the
  show report, and both delete summaries. The locale is pinned and the
  assertions read the English msgids, so the tests do not move under the
  translations, and the verbs are called as `Account.run/1` rather than
  through `Pesque.Cli.run/1`, whose entry locale resolution would override
  the pin from the environment.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.Token
  alias Pesque.Cli.Account
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoStore

  @password "hunter2hunter2"

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    Pesque.DataCase.setup()

    # path_multi so the account gets a handle: under conformant_single the
    # seeded server row has no handle and every account compares as taken.
    previous = Application.get_env(:pesque, :mode)
    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
    Application.put_env(:pesque, :mode, :path_multi)

    handle = "opview" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  describe "account list --status" do
    test "answers the accounts that can write, and not the deactivated one", %{user: user} do
      {:ok, other} = Accounts.create_account(other_handle(), "bob@localhost", @password)
      {:ok, _} = Accounts.deactivate_account(other)

      output = capture(fn -> assert :ok = Account.run(["list", "--status", "active"]) end)

      assert output =~ user.did
      refute output =~ other.did
    end

    test "answers the deactivated accounts, and not the active one", %{user: user} do
      {:ok, other} = Accounts.create_account(other_handle(), "bob@localhost", @password)
      {:ok, _} = Accounts.deactivate_account(other)

      output = capture(fn -> assert :ok = Account.run(["list", "--status", "deactivated"]) end)

      assert output =~ other.did
      refute output =~ user.did
    end

    test "without --status every account answers, as before", %{user: user} do
      {:ok, other} = Accounts.create_account(other_handle(), "bob@localhost", @password)
      {:ok, _} = Accounts.deactivate_account(other)

      output = capture(fn -> assert :ok = Account.run(["list"]) end)

      assert output =~ user.did
      assert output =~ other.did
    end

    test "an unknown status is usage, not an empty list that reads as no accounts" do
      assert {:usage, text} = Account.run(["list", "--status", "archived"])
      assert text =~ "usage"
    end
  end

  describe "account list --grep" do
    test "matches a substring of the handle, case-insensitively", %{user: user} do
      {:ok, other} = Accounts.create_account(other_handle(), "bob@localhost", @password)

      output =
        capture(fn ->
          assert :ok = Account.run(["list", "--grep", String.upcase(user.handle)])
        end)

      assert output =~ user.did
      refute output =~ other.did
    end

    test "matches over the email too", %{user: user} do
      {:ok, other} = Accounts.create_account(other_handle(), "bob@localhost", @password)

      output = capture(fn -> assert :ok = Account.run(["list", "--grep", "ALICE@LOCALHOST"]) end)

      assert output =~ user.did
      refute output =~ other.did
    end

    test "composes with --status, and a miss answers the header alone", %{user: user} do
      output =
        capture(fn ->
          assert :ok =
                   Account.run(["list", "--status", "deactivated", "--grep", user.handle])
        end)

      refute output =~ user.did
    end
  end

  describe "account show" do
    test "answers the row, its app passwords and the repo rev", %{user: user} do
      RepoStore.put_meta!("rev:" <> user.did, "rev-from-the-test")
      {:ok, _} = Accounts.create_app_password(user, "shown", true)

      output = capture(fn -> assert :ok = Account.run(["show", "--did", user.did]) end)

      assert output =~ user.did
      assert output =~ user.handle
      assert output =~ "alice@localhost"
      assert output =~ "active"
      assert output =~ "rev-from-the-test"
      assert output =~ "shown"
      assert output =~ "privileged"
    end

    test "resolves by handle and answers the empty cases", %{user: user} do
      output = capture(fn -> assert :ok = Account.run(["show", "--handle", user.handle]) end)

      assert output =~ user.did
      assert output =~ "no app passwords"
      assert output =~ "repo rev"
      assert output =~ "deactivated at"
    end

    test "an account this server does not host answers not_found" do
      assert {:error, :not_found} = Account.run(["show", "--did", "did:web:nope:nobody"])
    end
  end

  describe "account delete --dry-run" do
    test "prints what would go and changes nothing", %{user: user} do
      RepoStore.put_record!(user.did, "app.bsky.feed.post", "3kat", "cid-1", "record bytes")
      RepoStore.insert_blocks!(user.did, %{"cid-1" => "block bytes"})
      # create_account already emitted the account's first event row.

      before = Accounts.describe_deletion(user)

      output =
        capture(fn ->
          assert :ok = Account.run(["delete", "--did", user.did, "--dry-run"])
        end)

      assert output =~ "this permanently deletes the account and its repo; it cannot be undone"
      assert output =~ "firehose events already emitted survive this deletion"
      assert output =~ "dry run: nothing was deleted"
      assert output =~ user.did
      assert output =~ before.key_path
      assert output =~ before.rotation_key_path
      assert output =~ before.blob_dir
      assert output =~ "repo records"
      assert output =~ "repo blocks"
      assert output =~ "firehose events"

      # The dry run read; it did not write. The facts are the same after, the
      # account and its key file are still here, and no deletion token was
      # minted (the real run mints one before it asks for the password).
      assert Accounts.describe_deletion(user) == before
      assert Accounts.get_user(user.did)
      assert File.exists?(Keys.path(user.did))

      refute Repo.exists?(
               from t in Token, where: t.did == ^user.did and t.purpose == :account_delete
             )
    end
  end

  defp capture(fun), do: ExUnit.CaptureIO.capture_io(fun)

  defp other_handle do
    "grepped" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
  end
end
