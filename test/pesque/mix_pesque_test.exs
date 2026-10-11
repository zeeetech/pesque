defmodule Pesque.MixPesqueTest do
  @moduledoc """
  The mix task's `--password` flag is dev convenience, and its one job beyond
  convenience is to not exist at the verb boundary: the argv handed to
  `Pesque.Cli.run/1` carries no flag and no value, and the value travels in
  the conventional environment variable the verb already reads.
  """

  use ExUnit.Case, async: false

  # `Mix.Pesque` is spelled out below on purpose: an alias of it would shadow
  # the `Pesque.` root this module's DataCase reference needs.
  describe "split_password/1" do
    test "the dispatched argv carries neither the flag nor the value" do
      argv = [
        "account",
        "create",
        "--handle",
        "alice.example.com",
        "--email",
        "a@example.com",
        "--password",
        "secret123"
      ]

      assert {"secret123", dispatched} = Mix.Pesque.split_password(argv)

      assert dispatched ==
               ["account", "create", "--handle", "alice.example.com", "--email", "a@example.com"]

      refute Enum.member?(dispatched, "--password")
      refute Enum.member?(dispatched, "secret123")
    end

    test "the equals form lifts" do
      assert {"secret123", dispatched} = Mix.Pesque.split_password(["--password=secret123", "x"])
      assert dispatched == ["x"]
    end

    test "a --password-env named alongside the flag comes out too" do
      argv = ["create", "--password", "secret123", "--password-env", "PESQUE_PASSWORD"]

      assert {"secret123", dispatched} = Mix.Pesque.split_password(argv)

      refute Enum.member?(dispatched, "--password-env")
      refute Enum.member?(dispatched, "PESQUE_PASSWORD")
    end

    test "without the flag, the argv passes through and --password-env stays" do
      argv = ["migrate", "--old-pds", "https://bsky.social", "--password-env", "MIGRATE_PASSWORD"]
      assert {nil, ^argv} = Mix.Pesque.split_password(argv)
    end

    test "a flag left with no value stays for the verb to answer usage on" do
      assert {nil, ["--password"]} = Mix.Pesque.split_password(["--password"])
    end
  end

  describe "the create task's --password flag" do
    setup do
      Pesque.DataCase.setup()
      put_mode(:path_multi)
      :ok
    end

    test "creates the account with the value carried by env, never argv" do
      handle = unique("argvsafe")

      Mix.Tasks.Pesque.CreateAccount.run([
        "--handle",
        handle <> ".localhost",
        "--email",
        "argvsafe@localhost",
        "--password",
        "secret123-secret"
      ])

      assert {:ok, _user} =
               Pesque.Accounts.verify_login(handle <> ".localhost", "secret123-secret")

      # The value did not outlive the dispatch in the environment either.
      refute System.get_env("ACCOUNT_PASSWORD") == "secret123-secret"
    end

    test "the flag outranks --password-env" do
      handle = unique("precedence")

      System.put_env("PESQUE_TEST_PASSWORD", "env-password-1")
      on_exit(fn -> System.delete_env("PESQUE_TEST_PASSWORD") end)

      Mix.Tasks.Pesque.CreateAccount.run([
        "--handle",
        handle <> ".localhost",
        "--email",
        "precedence@localhost",
        "--password",
        "flag-password-1",
        "--password-env",
        "PESQUE_TEST_PASSWORD"
      ])

      assert {:ok, _user} =
               Pesque.Accounts.verify_login(handle <> ".localhost", "flag-password-1")

      assert :error = Pesque.Accounts.verify_login(handle <> ".localhost", "env-password-1")
    end
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
