defmodule Pesque.MixPesqueTest do
  @moduledoc """
  The mix tasks are the dev-mode spelling of the release verbs: they dispatch
  the same `Pesque.Cli.run/1`, with no password flag of their own. A password
  comes from the verb's no-echo prompt or from stdin, like everywhere else.
  """

  use ExUnit.Case, async: false

  # The account task prints the account table, as it does on a real boot.
  # Capture it so the suite output stays clean.
  import ExUnit.CaptureIO

  describe "the account task" do
    setup do
      Pesque.DataCase.setup()
      put_mode(:path_multi)
      :ok
    end

    test "runs the verb and dispatches no password" do
      assert capture_io(fn ->
               assert :ok = Mix.Tasks.Pesque.Account.run(["list"])
             end) =~ "did"
    end

    test "--password is no longer a flag: the verb answers usage" do
      assert_raise Mix.Error, ~r/unknown option: --password/, fn ->
        capture_io(fn ->
          Mix.Tasks.Pesque.CreateAccount.run([
            "--handle",
            "argv.example.com",
            "--email",
            "argv@example.com",
            "--password",
            "secret123"
          ])
        end)
      end
    end
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
