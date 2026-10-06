defmodule Pesque.BlockSweepTest do
  @moduledoc """
  Two retention sweeps that share a timer: firehose events past their window,
  and blocks no current MST can reach.

  The block sweep is the one with a way to lose data, so it is pinned from
  both sides: every block a reader can still name survives, and every block
  nothing reaches goes.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts.User
  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event

  setup do
    Pesque.DataCase.setup()

    alice = account("alice")
    bob = account("bob")

    %{alice: alice, bob: bob, alice_repo: start_repo(alice.did), bob_repo: start_repo(bob.did)}
  end

  test "every block reachable from the current MST survives a sweep", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "2", post("two"))
    {:ok, _} = RepoServer.create_record(ctx.bob_repo, "app.bsky.feed.post", "1", post("bob"))

    RepoStore.sweep_blocks!(ctx.alice.did)

    after_sweep = stored_cids(ctx.alice.did)

    assert MapSet.member?(after_sweep, record_cid(ctx.alice.did, "1"))
    assert MapSet.member?(after_sweep, record_cid(ctx.alice.did, "2"))
    assert MapSet.member?(after_sweep, RepoStore.get_meta("root:" <> ctx.alice.did))
    assert MapSet.member?(after_sweep, RepoStore.get_meta("commit:" <> ctx.alice.did))
  end

  # The tree is rebuilt from scratch on every commit, so the nodes the
  # previous commits built are unreachable the moment the next commit lands.
  # A sweep that kept them would never collect anything.
  test "the tree nodes and commits earlier commits built are collected", ctx do
    genesis = RepoStore.get_meta("commit:" <> ctx.alice.did)

    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))
    superseded = RepoStore.get_meta("commit:" <> ctx.alice.did)

    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "2", post("two"))

    before = stored_cids(ctx.alice.did)

    assert RepoStore.sweep_blocks!(ctx.alice.did) > 0

    swept = stored_cids(ctx.alice.did)

    refute MapSet.member?(swept, genesis), "a superseded commit block was kept"
    refute MapSet.member?(swept, superseded), "a superseded commit block was kept"
    assert MapSet.member?(swept, RepoStore.get_meta("commit:" <> ctx.alice.did))
    assert MapSet.size(swept) < MapSet.size(before)
  end

  test "the repo still serves a CAR and every record after a sweep", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "2", post("two"))

    RepoStore.sweep_blocks!(ctx.alice.did)

    stored = Map.new(RepoStore.blocks_for(ctx.alice.did), &{&1.cid, &1.data})
    marked = reachable(stored, RepoStore.get_meta("root:" <> ctx.alice.did))

    assert Enum.all?(marked, &Map.has_key?(stored, &1)), "a reachable block was swept"

    assert RepoStore.get_record(ctx.alice.did, "app.bsky.feed.post", "1")
    assert RepoStore.get_record(ctx.alice.did, "app.bsky.feed.post", "2")
    assert RepoStore.get_block(ctx.alice.did, RepoStore.get_meta("commit:" <> ctx.alice.did))
  end

  test "a block no MST reaches is deleted", ctx do
    {:ok, first} =
      RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))

    superseded = change_cid(first)
    before = RepoStore.block_count(ctx.alice.did)

    {:ok, _} = RepoServer.put_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("two"))

    assert RepoStore.block_count(ctx.alice.did) > before
    assert RepoStore.sweep_blocks!(ctx.alice.did) > 0
    assert RepoStore.get_block(ctx.alice.did, superseded) == nil
  end

  # Another account's identical block is stored under that account's DID, so
  # one repo's sweep can never take out another's.
  test "a sweep of one repo leaves another repo's blocks alone", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))
    before = stored_cids(ctx.bob.did)

    RepoStore.sweep_blocks!(ctx.alice.did)

    assert stored_cids(ctx.bob.did) == before
  end

  test "a repo with no head is not swept at all" do
    did = "did:web:localhost:user:headless" <> unique("x")

    RepoStore.insert_blocks!(did, %{
      "bafyreifakefakefakefakefakefakefakefakefakefake" => <<1, 2, 3>>
    })

    assert RepoStore.sweep_blocks!(did) == 0
    assert RepoStore.block_count(did) == 1
  end

  # The walk cannot say what hangs below a block it cannot decode, so it must
  # not delete anything at all: deleting on a partial walk is how a repo loses
  # a record a reader can still ask for by CID.
  test "a sweep that cannot decode a block the tree names deletes nothing", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))
    before = stored_cids(ctx.alice.did)

    junk = CID.from_data(<<0xFF, 0xFF, 0xFF>>)
    {root, root_bytes} = tree_over(junk)
    RepoStore.insert_blocks!(ctx.alice.did, %{CID.to_string(root) => root_bytes})
    RepoStore.insert_blocks!(ctx.alice.did, %{CID.to_string(junk) => <<0xFF, 0xFF, 0xFF>>})
    RepoStore.put_meta!("root:" <> ctx.alice.did, CID.to_string(root))

    assert RepoStore.sweep_blocks!(ctx.alice.did) == 0

    assert stored_cids(ctx.alice.did) ==
             MapSet.union(before, MapSet.new([CID.to_string(junk), CID.to_string(root)]))

    assert RepoStore.get_record(ctx.alice.did, "app.bsky.feed.post", "1")
  end

  test "delete_events_before drops events older than the cutoff and keeps the rest", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))

    old = DateTime.add(DateTime.utc_now(), -8, :day) |> DateTime.truncate(:second)
    Repo.update_all(Event, set: [inserted_at: old])

    before = Repo.aggregate(Event, :count)

    assert RepoStore.delete_events_before(DateTime.utc_now()) == before

    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "2", post("two"))

    assert Repo.aggregate(Event, :count) == 1
    assert RepoStore.delete_events_before(DateTime.utc_now()) == 0
    assert RepoStore.max_seq() > 0
  end

  test "a cutoff older than every event deletes nothing", ctx do
    {:ok, _} = RepoServer.create_record(ctx.alice_repo, "app.bsky.feed.post", "1", post("one"))

    before = Repo.aggregate(Event, :count)
    cutoff = DateTime.add(DateTime.utc_now(), -1, :hour) |> DateTime.truncate(:second)

    assert RepoStore.delete_events_before(cutoff) == 0
    assert Repo.aggregate(Event, :count) == before
  end

  # An MST node with one entry pointing at `child`, hand-built so the tree
  # names a block the walk cannot decode. Answers {root_cid, node_bytes}.
  defp tree_over(child) do
    bytes =
      CBOR.encode(%{
        "e" => [
          %{
            "k" => %CBOR.Bytes{data: "app.bsky.feed.post/1"},
            "p" => 0,
            "t" => nil,
            "v" => child
          }
        ],
        "l" => nil
      })

    {CID.from_data(bytes), bytes}
  end

  defp reachable(stored, cid_string, seen \\ MapSet.new())

  defp reachable(stored, cid_string, seen) do
    if MapSet.member?(seen, cid_string) do
      seen
    else
      children =
        case Map.fetch(stored, cid_string) do
          :error -> []
          {:ok, data} -> children_of(data)
        end

      Enum.reduce(children, MapSet.put(seen, cid_string), &reachable(stored, &1, &2))
    end
  end

  defp children_of(data) do
    case Pesque.CBOR.decode(data) do
      {:ok, %{"l" => left, "e" => entries}} ->
        Enum.flat_map([left | Enum.map(entries, &{&1["t"], &1["v"]})], fn
          %CID{} = cid -> [CID.to_string(cid)]
          _not_a_link -> []
        end)

      _record_or_anything_else ->
        []
    end
  end

  defp record_cid(did, rkey) do
    RepoStore.get_record(did, "app.bsky.feed.post", rkey).cid
  end

  defp change_cid(%{"changes" => [%{"cid" => cid}]}), do: cid

  defp stored_cids(did) do
    RepoStore.blocks_for(did) |> MapSet.new(& &1.cid)
  end

  defp account(name) do
    username = unique(name)

    %{
      did: "did:web:localhost:user:" <> username,
      handle: username <> ".localhost",
      email: username <> "@localhost",
      password_hash: "not-a-real-hash"
    }
    |> User.changeset()
    |> Repo.insert!()
  end

  # A call round trip, not the pid, guarantees the genesis commit in
  # handle_continue/2 has already run.
  defp start_repo(did) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(did)
    RepoServer.entries(pid)
    pid
  end

  defp post(text) do
    %{"$type" => "app.bsky.feed.post", "text" => text, "createdAt" => "2026-01-01T00:00:00.000Z"}
  end

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
