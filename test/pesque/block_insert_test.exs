defmodule Pesque.BlockInsertTest do
  @moduledoc """
  insert_blocks!/2 batches rows under SQLite's bound-variable ceiling.

  A migration hands it a whole repo at once, and a personal account is tens of
  thousands of blocks. One insert_all would bind four parameters per row, which
  is more than a single statement may carry.
  """

  use ExUnit.Case, async: false

  alias Pesque.RepoStore

  # Past the ceiling at four parameters per row (32766 / 4 = 8191), so a single
  # insert_all would be refused by SQLite.
  @blocks 9_000

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "inserts more blocks than one statement can bind" do
    did = "did:web:localhost:user:batch"
    blocks = Map.new(1..@blocks, fn n -> {"cid-#{n}", "data #{n}"} end)

    RepoStore.insert_blocks!(did, blocks)

    assert RepoStore.blocks_map(did) |> map_size() == @blocks
  end
end
