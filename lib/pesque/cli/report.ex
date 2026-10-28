defmodule Pesque.Cli.Report do
  @moduledoc """
  The plain "next steps" block a multi-step verb ends with, and the account
  summary the creation verb prints.

  No status marks, no spinners, no live redraw: the one-off usually runs
  without a TTY, and a plain block is what survives a pipe. Rendering is pure;
  the caller prints the block, so the stream it lands on stays the caller's.
  """

  use Gettext, backend: PesqueWeb.Gettext

  @doc """
  Renders the steps in order with a blank line between two of them. A step may
  span lines of its own; its interior layout is the caller's.
  """
  @spec next_steps([String.t()]) :: String.t()
  def next_steps(steps) do
    Enum.join(steps, "\n\n")
  end

  @doc """
  Prints the account and what to do next, the part of account creation the
  account verbs share.
  """
  def print_account(account, opts \\ []) do
    IO.puts("")

    [
      gettext("Account created.") <> "\n  handle  #{account.handle}\n  did     #{account.did}",
      gettext(
        "Point this domain at the server, then add the handle record, and give DNS a few minutes to catch up:"
      ) <>
        "\n\n" <> Enum.join(dns_lines(account, opts[:public_ip]), "\n"),
      gettext("Check that everything is reachable from outside:") <> "\n\n  pesque doctor"
    ]
    |> next_steps()
    |> IO.puts()
  end

  # A did:web account serves its own handle at /.well-known/atproto-did, so
  # only the host record is needed. A multi account is resolved at
  # _atproto.<handle>, which nothing else publishes, so the TXT carries the
  # DID the directory minted.
  defp dns_lines(%{did: "did:plc:" <> _} = account, public_ip) do
    [host_line(public_ip), "  _atproto.#{account.handle}   TXT    \"did=#{account.did}\""]
  end

  defp dns_lines(_account, public_ip), do: [host_line(public_ip)]

  defp host_line(public_ip) do
    ip =
      case public_ip do
        value when is_binary(value) and value != "" -> value
        _unset -> "<this server's public IP>"
      end

    "  #{Pesque.hostname()}   A      #{ip}"
  end
end
