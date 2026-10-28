defmodule Pesque.ReleaseTest do
  @moduledoc """
  The account printer: the summary and the next steps as one block, rendered
  through `Pesque.Cli.Report`. The locale is pinned and the assertions read the
  English msgids, the way `Pesque.Cli.ExplainTest` does.
  """

  use ExUnit.Case, async: false

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  test "print_account renders the summary, the DNS step and the doctor step" do
    account = %{handle: "zoey.localhost", did: "did:web:zoey.localhost"}

    output = ExUnit.CaptureIO.capture_io(fn -> Pesque.Release.print_account(account) end)

    assert output =~ "Account created."
    assert output =~ "  handle  zoey.localhost"
    assert output =~ "  did     did:web:zoey.localhost"
    assert output =~ "Point this domain at the server"
    assert output =~ "  localhost   A"
    assert output =~ "Check that everything is reachable from outside:"
    assert output =~ "  pesque doctor"
  end

  test "the block keeps a blank line between the steps" do
    account = %{handle: "zoey.localhost", did: "did:web:zoey.localhost"}

    output = ExUnit.CaptureIO.capture_io(fn -> Pesque.Release.print_account(account) end)

    assert output =~ "did     did:web:zoey.localhost\n\nPoint this domain at the server"
  end

  test "a did:plc account is told to publish its TXT record too" do
    account = %{handle: "zoey.localhost", did: "did:plc:abc234def567"}

    output = ExUnit.CaptureIO.capture_io(fn -> Pesque.Release.print_account(account) end)

    assert output =~ ~s(_atproto.zoey.localhost   TXT    "did=did:plc:abc234def567")
  end

  test "a supplied public IP replaces the A record placeholder" do
    account = %{handle: "zoey.localhost", did: "did:web:zoey.localhost"}

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Pesque.Release.print_account(account, public_ip: "203.0.113.7")
      end)

    assert output =~ "  localhost   A      203.0.113.7"
  end
end
