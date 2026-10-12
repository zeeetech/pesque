defmodule Pesque.Cli.InputTest do
  @moduledoc """
  The input order: the flag, then the environment, then a prompt, checked by
  watching the prompt, which is a seam, so a flag or an environment value
  that answers first is visible as a prompt never asked.
  """

  use ExUnit.Case, async: false

  alias Pesque.Cli.Input

  defp no_prompt do
    fn prompt ->
      flunk("the prompt #{inspect(prompt)} was asked; a flag or env should have answered")
    end
  end

  describe "options/3" do
    test "parses known flags" do
      assert {:ok, [keep: "1"], []} =
               Input.options(["--keep", "1"], [keep: :string], "usage: pesque")
    end

    test "an unknown flag is usage" do
      assert {:usage, text} = Input.options(["--bogus"], [], "usage: pesque")
      assert text =~ "unknown option: --bogus"
    end

    test "a stray positional is usage unless the verb allows one" do
      assert {:usage, text} = Input.options(["stray"], [], "usage: pesque")
      assert text =~ "unexpected argument: stray"

      assert {:ok, [], ["stray"]} = Input.options(["stray"], [], "usage: pesque", true)
    end
  end

  describe "text/5" do
    test "the flag wins and the prompt is never asked" do
      assert {:ok, "flag.example.com"} =
               Input.text(
                 [handle: "flag.example.com"],
                 :handle,
                 "ACCOUNT_HANDLE",
                 "handle: ",
                 no_prompt()
               )
    end

    test "the environment is second" do
      System.put_env("ACCOUNT_HANDLE", "env.example.com")
      on_exit(fn -> System.delete_env("ACCOUNT_HANDLE") end)

      assert {:ok, "env.example.com"} =
               Input.text([], :handle, "ACCOUNT_HANDLE", "handle: ", no_prompt())
    end

    test "the prompt is last" do
      previous = System.get_env("ACCOUNT_HANDLE")
      System.delete_env("ACCOUNT_HANDLE")
      on_exit(fn -> if previous, do: System.put_env("ACCOUNT_HANDLE", previous) end)

      assert {:ok, "prompt.example.com"} =
               Input.text([], :handle, "ACCOUNT_HANDLE", "handle: ", fn _ ->
                 {:ok, "prompt.example.com"}
               end)
    end
  end

  describe "password/4" do
    test "--password-env reads the variable it names, never a value from argv" do
      System.put_env("PESQUE_TEST_PASSWORD", "from-env")
      on_exit(fn -> System.delete_env("PESQUE_TEST_PASSWORD") end)

      assert {:ok, "from-env"} =
               Input.password(
                 [password_env: "PESQUE_TEST_PASSWORD"],
                 "ACCOUNT_PASSWORD",
                 no_prompt()
               )
    end

    test "a named variable that is unset or empty fails naming it" do
      assert {:error, {:password_env_empty, "PESQUE_NO_SUCH_VAR"}} =
               Input.password(
                 [password_env: "PESQUE_NO_SUCH_VAR"],
                 "ACCOUNT_PASSWORD",
                 no_prompt()
               )

      # Set but empty is the same failure: an empty string travelling on as
      # the password would surface as a misleading password_too_short.
      System.put_env("PESQUE_EMPTY_PASSWORD", "")
      on_exit(fn -> System.delete_env("PESQUE_EMPTY_PASSWORD") end)

      assert {:error, {:password_env_empty, "PESQUE_EMPTY_PASSWORD"}} =
               Input.password(
                 [password_env: "PESQUE_EMPTY_PASSWORD"],
                 "ACCOUNT_PASSWORD",
                 no_prompt()
               )
    end

    # `export ACCOUNT_PASSWORD=$(cat pw.txt)` and `echo` both leave a trailing
    # newline, and a hash of "secret\n" is not the "secret" a browser sends
    # back: the env source has to trim like the prompt already does.
    test "an environment value is trimmed" do
      System.put_env("PESQUE_TEST_PASSWORD", "secret\n")
      on_exit(fn -> System.delete_env("PESQUE_TEST_PASSWORD") end)

      assert {:ok, "secret"} =
               Input.password(
                 [password_env: "PESQUE_TEST_PASSWORD"],
                 "ACCOUNT_PASSWORD",
                 no_prompt()
               )
    end

    test "the conventional environment is next" do
      System.put_env("ACCOUNT_PASSWORD", "conventional")
      on_exit(fn -> System.delete_env("ACCOUNT_PASSWORD") end)

      assert {:ok, "conventional"} = Input.password([], "ACCOUNT_PASSWORD", no_prompt())
    end

    test "the prompt is last" do
      previous = System.get_env("ACCOUNT_PASSWORD")
      System.delete_env("ACCOUNT_PASSWORD")
      on_exit(fn -> if previous, do: System.put_env("ACCOUNT_PASSWORD", previous) end)

      assert {:ok, "prompted"} =
               Input.password([], "ACCOUNT_PASSWORD", "password: ", fn _ -> {:ok, "prompted"} end)
    end
  end
end
