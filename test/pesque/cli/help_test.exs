defmodule Pesque.Cli.HelpTest do
  @moduledoc """
  The `{:help, text}` answer: `pesque <verb> [sub] --help` names the most
  specific usage and goes back through `run/1`, which `main/0` prints on
  stdout with exit 0. A verb reached without a subcommand stays `{:usage,
  text}`: no subcommand is an error, `--help` is a request. The tests read
  `run/1`'s answers, never `main/0`, which halts the VM.
  """

  use ExUnit.Case, async: false

  alias Pesque.Cli

  test "every verb answers --help with its usage" do
    for verb <- Cli.verbs() do
      assert {:help, text} = Cli.run([verb, "--help"])
      assert text =~ "usage"
    end
  end

  test "the help is the most specific usage: the verb's, then the subcommand's" do
    assert {:help, account} = Cli.run(["account", "--help"])
    assert account =~ "usage: pesque account <subcommand>"

    # The create answer is create's own usage, not the whole account menu.
    # It must come back without a boot or a prompt: the answer leaves the
    # clause before any input is read.
    assert {:help, create} = Cli.run(["account", "create", "--help"])
    assert create =~ "usage: pesque account create"
    refute create =~ "revoke-app-password"

    assert {:help, list} = Cli.run(["account", "list", "--help"])
    assert list =~ "usage: pesque account list"
    assert list =~ "--grep"

    assert {:help, delete} = Cli.run(["account", "delete", "--help"])
    assert delete =~ "usage: pesque account delete"
    assert delete =~ "--dry-run"

    assert {:help, validate} = Cli.run(["config", "validate", "--help"])
    assert validate =~ "usage: pesque config validate"
    refute validate =~ "template"
  end

  test "a flat verb answers --help with its own usage" do
    assert {:help, "usage: pesque status"} = Cli.run(["status", "--help"])
    assert {:help, text} = Cli.run(["restore", "--help"])
    assert text =~ "usage: pesque restore"
  end

  test "a verb with no subcommand stays usage, not help" do
    for verb <- ~w(account invite config crawl) do
      assert {:usage, text} = Cli.run([verb])
      assert text =~ "usage"
    end
  end
end
