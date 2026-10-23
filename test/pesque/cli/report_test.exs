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
