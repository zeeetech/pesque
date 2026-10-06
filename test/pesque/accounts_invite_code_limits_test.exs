defmodule Pesque.Accounts.InviteCodeLimitsTest do
  @moduledoc """
  The bounds on a mint, and what they cost.

  createInviteCodes materialises codeCount rows in memory before the single
  insert_all, so the count is bounded by what one call may cost rather than by
  what SQLite accepts. The useCount bound is a different thing: it multiplies
  what one code buys rather than what one call costs, and a code with a
  million uses is a closed registration with one extra step.

  These call the context directly. The counts are refused there on purpose, so
  a test that went through the endpoint would pass even if the context stopped
  checking, which is the half that has to hold.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.InviteCode
  alias Pesque.Repo

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
  end

  test "a codeCount inside the bound is minted" do
    assert {:ok, [%{account: nil, codes: codes}]} = Accounts.create_invite_codes(5, 1)
    assert length(codes) == 5
    assert Enum.all?(codes, &is_binary/1)
  end

  test "a codeCount past the bound is refused and mints nothing" do
    before = Repo.aggregate(InviteCode, :count)

    assert {:error, :invalid_code_count} = Accounts.create_invite_codes(1_000_001, 1)
    assert {:error, :invalid_code_count} = Accounts.create_invite_codes(100_000_000, 1)

    assert Repo.aggregate(InviteCode, :count) == before
  end

  test "a useCount past the bound is refused and mints nothing" do
    before = Repo.aggregate(InviteCode, :count)

    assert {:error, :invalid_use_count} = Accounts.create_invite_codes(1, 1_000_001)
    assert {:error, :invalid_use_count} = Accounts.create_invite_codes(1, 100_000_000)

    assert Repo.aggregate(InviteCode, :count) == before
  end

  # The exploit was one spent code plus a repeat of this call, so the bound on
  # useCount is the one that has to hold: the account that spent the first
  # invite cannot mint a code that outlasts it.
  test "the biggest code one call can make still admits a bounded number of accounts" do
    assert {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1_000)

    assert %InviteCode{use_count: 1_000} = Repo.get_by(InviteCode, code: code)
  end

  test "a count that is not a positive integer is still refused" do
    assert {:error, :invalid_code_count} = Accounts.create_invite_codes(0, 1)
    assert {:error, :invalid_code_count} = Accounts.create_invite_codes(-1, 1)
    assert {:error, :invalid_code_count} = Accounts.create_invite_codes("3", 1)
    assert {:error, :invalid_use_count} = Accounts.create_invite_codes(3, 0)
    assert {:error, :invalid_use_count} = Accounts.create_invite_codes(3, nil)
  end

  test "forAccounts is one group per DID and each is still inside the bound" do
    dids = ["did:web:localhost%3A4000:user:alice", "did:web:localhost%3A4000:user:bob"]

    assert {:ok, groups} = Accounts.create_invite_codes(2, 1, dids)

    assert Enum.map(groups, & &1.account) == dids
    assert Enum.all?(groups, &(length(&1.codes) == 2))
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
