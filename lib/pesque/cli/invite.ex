defmodule Pesque.Cli.Invite do
  @moduledoc """
  Mints invite codes for closed registration. The admin gate lives in the
  XRPC plug, not in the domain function, so an operator verb can call it
  directly.
  """

  alias Pesque.Accounts
  alias Pesque.Cli.Input
  alias Pesque.Release

  @usage "usage: pesque invite create [--count N] [--uses N] [--for DID]"

  def run(["create" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, [count: :integer, uses: :integer, for: :string], @usage),
         :ok <- Release.boot!() do
      count = opts[:count] || 1
      uses = opts[:uses] || 1
      for_dids = if opts[:for], do: [opts[:for]], else: []

      case Accounts.create_invite_codes(count, uses, for_dids) do
        {:ok, groups} ->
          print_groups(groups, uses)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(_argv), do: {:usage, @usage}

  defp print_groups(groups, uses) do
    for %{account: account, codes: codes} <- groups do
      case account do
        nil -> IO.puts("codes any account can spend, each good for #{uses}:")
        did -> IO.puts("codes for #{did}, each good for #{uses}:")
      end

      Enum.each(codes, &IO.puts("  " <> &1))
    end

    :ok
  end
end
