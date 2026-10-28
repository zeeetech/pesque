defmodule Pesque.Cli.ReportTest do
  @moduledoc """
  The shared next-steps block: steps in order, a blank line between two, no
  marks. Rendering is pure, so the assertions need no terminal, and the locale
  is pinned the way `Pesque.Cli.ExplainTest` pins it.
  """

  use ExUnit.Case, async: true

  alias Pesque.Cli.Report

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  test "renders one step as one line" do
    assert Report.next_steps(["run pesque doctor"]) == "run pesque doctor"
  end

  test "renders the steps in order with a blank line between two" do
    rendered = Report.next_steps(["first step", "second step", "third step"])

    assert rendered == "first step\n\nsecond step\n\nthird step"
  end

  test "a step may span lines of its own" do
    rendered = Report.next_steps(["add the records:\n\n  host A ip", "check from outside"])

    assert rendered == "add the records:\n\n  host A ip\n\ncheck from outside"
  end

  test "no steps render as an empty block" do
    assert Report.next_steps([]) == ""
  end
end

defmodule Pesque.Cli.ReportAccountTest do
  use ExUnit.Case, async: false

  alias Pesque.Cli.Report

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  test "prints the summary, the DNS step and the doctor step" do
    account = %{handle: "zoey.localhost", did: "did:web:zoey.localhost"}

    output = ExUnit.CaptureIO.capture_io(fn -> Report.print_account(account) end)

    assert output =~ "Account created."
    assert output =~ "  handle  zoey.localhost"
    assert output =~ "  did     did:web:zoey.localhost"
    assert output =~ "Point this domain at the server"
    assert output =~ "  localhost   A"
    assert output =~ "Check that everything is reachable from outside:"
    assert output =~ "  pesque doctor"
  end

  test "a did:plc account is told to publish its TXT record too" do
    account = %{handle: "zoey.localhost", did: "did:plc:abc234def567"}

    output = ExUnit.CaptureIO.capture_io(fn -> Report.print_account(account) end)

    assert output =~ ~s(_atproto.zoey.localhost   TXT    "did=did:plc:abc234def567")
  end

  test "a supplied public IP replaces the A record placeholder" do
    account = %{handle: "zoey.localhost", did: "did:web:zoey.localhost"}

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Report.print_account(account, public_ip: "203.0.113.7")
      end)

    assert output =~ "  localhost   A      203.0.113.7"
  end
end
