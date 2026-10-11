defmodule Pesque.CliTest do
  @moduledoc """
  Dispatch totality and the exit-code mapping, through `run/1` and never
  `main/0`: main halts the VM, and `run/1` answers the same three answers
  main maps onto 0, 1 and 2.
  """

  use ExUnit.Case, async: false

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
    test "run/1 answers only :ok, {:error, reason} or {:usage, text}" do
      answers = [Cli.run([]), Cli.run(["bogus"]), Cli.run(["config", "bogus-sub"])]

      assert Enum.all?(answers, fn
               :ok -> true
               {:error, _reason} -> true
               {:usage, _text} -> true
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
      assert output =~ "hostname"
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

  defp restore_config(previous) do
    if previous, do: System.put_env("PDS_CONFIG", previous), else: System.delete_env("PDS_CONFIG")
  end
end
