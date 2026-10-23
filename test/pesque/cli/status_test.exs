defmodule Pesque.Cli.StatusTest do
  @moduledoc """
  The report is a pure function over a plain data map, so the assertions run
  without booting the app; the usage refusals answer before the boot too. The
  locale is pinned and the assertions read the English msgids, like the
  explain tests.
  """

  use ExUnit.Case, async: false

  alias Pesque.Cli.Status

  setup do
    Gettext.put_locale(PesqueWeb.Gettext, "en")
    :ok
  end

  defp data do
    %{
      server: %{
        did: "did:plc:abc123",
        hostname: "example.com",
        handle_domain: "example.com",
        mode: :conformant_single,
        identity: :web,
        registration: :closed,
        version: "1.13.3"
      },
      accounts: %{total: 3, active: 2, deactivated: 1},
      storage: %{
        data_dir: "/var/pesque/data",
        database_bytes: 10_240,
        blob_bytes: 2_048
      },
      crawlers: ["https://bsky.network"]
    }
  end

  describe "run/1" do
    test "an unknown option is usage, before any boot" do
      assert {:usage, text} = Status.run(["--wat"])

      assert text =~ "unknown option: --wat"
      assert text =~ "usage: pesque status"
    end

    test "a stray argument is usage too" do
      assert {:usage, text} = Status.run(["extra"])

      assert text =~ "unexpected argument: extra"
      assert text =~ "usage: pesque status"
    end
  end

  describe "report/1" do
    test "renders the sections: server, accounts, storage, crawlers" do
      text = render(data())

      assert text == """
             server
               did            did:plc:abc123
               hostname       example.com
               handle domain  example.com
               mode           conformant_single
               identity       web
               registration   closed
               version        1.13.3

             accounts
               total          3
               active         2
               deactivated    1

             storage
               data dir       /var/pesque/data
               database       10240 bytes
               blobs          2048 bytes

             crawlers
               https://bsky.network
             """
    end

    test "no crawler configured reads none configured, not an empty section" do
      text = render(put_in(data().crawlers, []))

      assert text =~ "crawlers\n  none configured"
      refute text =~ "https://"
    end

    test "renders the counts it was handed" do
      text = render(put_in(data().accounts, %{total: 1, active: 1, deactivated: 0}))

      assert text =~ "total          1"
      assert text =~ "active         1"
      assert text =~ "deactivated    0"
    end
  end

  defp render(data) do
    # The trailing newline the last printed line ends with.
    text = data |> Status.report() |> Enum.map_join("\n", &IO.iodata_to_binary/1)
    text <> "\n"
  end
end
