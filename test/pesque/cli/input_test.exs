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

    test "--help answers the usage it was given, before any parsing" do
      assert {:help, "usage: pesque"} = Input.options(["--help"], [], "usage: pesque")
      assert {:help, "usage: pesque"} = Input.options(["--bogus", "--help"], [], "usage: pesque")
    end

    test "-h answers the same usage, before any parsing" do
      assert {:help, "usage: pesque"} = Input.options(["-h"], [], "usage: pesque")
      assert {:help, "usage: pesque"} = Input.options(["--bogus", "-h"], [], "usage: pesque")
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

  describe "password/2" do
    test "the prompt is the source, and stdin is the fallback" do
      assert {:ok, "prompted"} =
               Input.password("password: ", fn _ -> {:ok, "prompted"} end)
    end

    test "a closed stdin is :no_input, not an empty password" do
      assert {:error, :no_input} = Input.password("password: ", fn _ -> {:error, :no_input} end)
    end
  end
end
