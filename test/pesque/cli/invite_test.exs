defmodule Pesque.Cli.InviteTest do
  @moduledoc """
  What a mint prints: the ready signup link where a signup page exists
  (path_multi), the bare codes with the account verb where it does not
  (conformant_single, where /signup answers 404).
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts.InviteCode
  alias Pesque.Cli.Invite
  alias Pesque.Repo

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    Pesque.DataCase.setup()
    :ok
  end

  test "under path_multi each code prints as the ready signup link" do
    put_mode(:path_multi)

    output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Invite.run(["create"]) end)

    assert [code] = minted_codes()
    assert output =~ "\n  #{Pesque.base_url()}/signup?code=#{code}\n"
    refute output =~ "pesque account create"
  end

  test "under conformant_single the codes print bare and name the account verb" do
    put_mode(:conformant_single)

    output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Invite.run(["create"]) end)

    assert [code] = minted_codes()
    assert output =~ "\n  #{code}\n"
    assert output =~ "pesque account create"
    refute output =~ "/signup?code="
  end

  # The verb mints its own codes, so what was printed is read back from the
  # row the run wrote. The default count is one.
  defp minted_codes do
    Repo.all(InviteCode) |> Enum.map(& &1.code)
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)
    Application.put_env(:pesque, :mode, mode)
    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
  end
end
