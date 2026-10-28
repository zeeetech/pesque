defmodule Pesque.CliTest do
  @moduledoc """
  Dispatch totality and the exit-code mapping, through `run/1` and never
  `main/0`: main halts the VM, and `run/1` answers the same three answers
  main maps onto 0, 1 and 2.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Cli

  describe "dispatch totality" do
    test "every verb answers usage for arguments nothing can parse" do
      for verb <- Cli.verbs() do
        # A subcommand verb answers usage at its own door; a flag verb gets
        # as far as flag parsing and answers usage there. Either way nothing
        # runs and nothing crashes.
        assert {:usage, text} = Cli.run([verb, "--not-a-real-flag"])
        assert text =~ "usage"
      end
    end

    test "verbs that take a subcommand answer usage without one" do
      for verb <- ~w(account invite config crawl) do
        assert {:usage, _text} = Cli.run([verb])
      end
    end

    test "the empty command line and an unknown command answer usage" do
      assert {:usage, text} = Cli.run([])
      assert text =~ "usage: pesque"

      assert {:usage, text} = Cli.run(["bogus"])
      assert text =~ "unknown command: bogus"
    end
  end

  describe "exit mapping" do
    # The mapping itself lives in main/0, which halts and cannot be called
    # from a test. What is testable is that run/1 answers exactly the three
    # shapes the mapping reads, whatever argv comes in.
    test "run/1 answers only :ok, {:error, reason}, {:usage, text} or {:help, text}" do
      answers = [Cli.run([]), Cli.run(["bogus"]), Cli.run(["config", "bogus-sub"])]

      assert Enum.all?(answers, fn
               :ok -> true
               {:error, _reason} -> true
               {:usage, _text} -> true
               {:help, _text} -> true
               other -> flunk("run/1 answered #{inspect(other)}")
             end)
    end
  end

  describe "config validate" do
    test "reports provenance for every key" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["config", "validate"])
        end)

      assert output =~ "config file:"
      assert output =~ "public_url"
      assert output =~ "(derived from public_url)"
      assert output =~ "(default)"
    end

    test "fails naming an unknown PDS_ variable" do
      System.put_env("PDS_NOT_A_REAL_KEY", "1")
      on_exit(fn -> System.delete_env("PDS_NOT_A_REAL_KEY") end)

      assert {:error, {:unknown_env, ["PDS_NOT_A_REAL_KEY"]}} = Cli.run(["config", "validate"])
    end

    test "fails naming the line of an unknown key in the config file" do
      path =
        Path.join(System.tmp_dir!(), "pesque-cli-bad-#{System.unique_integer([:positive])}.conf")

      File.write!(path, "hostnmae = typo.example.com\n")
      on_exit(fn -> File.rm(path) end)

      previous = System.get_env("PDS_CONFIG")
      System.put_env("PDS_CONFIG", path)
      on_exit(fn -> restore_config(previous) end)

      assert {:error, {:unknown_key, "hostnmae", 1}} = Cli.run(["config", "validate"])
    end
  end

  describe "account app-passwords" do
    # The verbs boot the app themselves, like every account verb; the database
    # setup is what makes the rows the verbs read.
    setup do
      Pesque.DataCase.setup()

      # multi so the account gets a handle: under single the
      # seeded server row has no handle and every account compares as taken.
      previous = Application.get_env(:pesque, :mode)
      on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
      Application.put_env(:pesque, :mode, :multi)

      handle =
        "appword" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"

      {:ok, user} = Accounts.create_account(handle, "alice@localhost", "hunter2hunter2")

      %{user: user}
    end

    test "the list verb prints rows with names and privileges", %{user: user} do
      {:ok, _} = Accounts.create_app_password(user, "listed", true)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["account", "app-passwords", "--did", user.did])
        end)

      assert output =~ "listed"
      assert output =~ "privileged"
    end

    test "the list verb names the empty case", %{user: user} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["account", "app-passwords", "--handle", user.handle])
        end)

      assert output =~ "no app passwords for #{user.handle}"
    end

    test "revoke-app-password takes the name from the environment, then the prompt",
         %{user: user} do
      # The prompt is the last source, fed here rather than left to whatever
      # stdin the runner has: on a terminal it would block waiting for a line,
      # so the test must not depend on stdin being closed.
      previous = System.get_env("APP_PASSWORD_NAME")
      System.delete_env("APP_PASSWORD_NAME")
      on_exit(fn -> if previous, do: System.put_env("APP_PASSWORD_NAME", previous) end)

      {:ok, _} = Accounts.create_app_password(user, "typed", false)

      output =
        ExUnit.CaptureIO.capture_io(:stdio, "typed\n", fn ->
          assert :ok = Cli.run(["account", "revoke-app-password", "--did", user.did])
        end)

      assert output =~ "revoked app password typed"

      {:ok, _} = Accounts.create_app_password(user, "envnamed", false)
      System.put_env("APP_PASSWORD_NAME", "envnamed")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["account", "revoke-app-password", "--did", user.did])
        end)

      assert output =~ "revoked app password envnamed"
    end

    test "revoke-app-password revokes by name and distinguishes nothing to do", %{user: user} do
      {:ok, _} = Accounts.create_app_password(user, "doomed", false)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Cli.run([
                     "account",
                     "revoke-app-password",
                     "--did",
                     user.did,
                     "--name",
                     "doomed"
                   ])
        end)

      assert output =~ "revoked app password doomed"
      assert output =~ "its sessions are revoked"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Cli.run([
                     "account",
                     "revoke-app-password",
                     "--did",
                     user.did,
                     "--name",
                     "doomed"
                   ])
        end)

      assert output =~ "nothing to do"
    end

    test "an unknown account answers not_found for both verbs", %{user: user} do
      assert {:error, :not_found} =
               Cli.run(["account", "app-passwords", "--did", "did:web:nope:nobody"])

      assert {:error, :not_found} =
               Cli.run([
                 "account",
                 "revoke-app-password",
                 "--did",
                 "did:web:nope:nobody",
                 "--name",
                 "n"
               ])

      _ = user
    end
  end

  describe "account email-token and reset-token" do
    # Like the other account verbs, these boot the app themselves; the database
    # setup is what makes the rows and the keys the verbs read.
    setup do
      Pesque.DataCase.setup()

      previous = Application.get_env(:pesque, :mode)
      on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
      Application.put_env(:pesque, :mode, :multi)

      handle =
        "codetok" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"

      {:ok, user} = Accounts.create_account(handle, "alice@localhost", "hunter2hunter2")

      %{user: user}
    end

    test "email-token prints a single-use code for the account", %{user: user} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["account", "email-token", "--did", user.did])
        end)

      assert output =~ "email token for #{user.did}:"
      assert output =~ "confirmEmail or updateEmail spends it"
    end

    test "reset-token prints a single-use code for the account", %{user: user} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Cli.run(["account", "reset-token", "--handle", user.handle])
        end)

      assert output =~ "password reset token for #{user.did}:"
      assert output =~ "resetPassword spends it"
    end

    test "an unknown account answers not_found for both verbs", %{user: user} do
      assert {:error, :not_found} =
               Cli.run(["account", "email-token", "--did", "did:web:nope:nobody"])

      assert {:error, :not_found} =
               Cli.run(["account", "reset-token", "--did", "did:web:nope:nobody"])

      _ = user
    end
  end

  defp restore_config(previous) do
    if previous, do: System.put_env("PDS_CONFIG", previous), else: System.delete_env("PDS_CONFIG")
  end
end
