defmodule Pesque.EventReaperTest do
  @moduledoc """
  The maintenance sweep as one call: events past their window go, blocks no
  current tree reaches go, and everything reachable stays.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts.User
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.RepoStore.Event

  setup do
    Pesque.DataCase.setup()

    alice = account("alice")

    %{alice: alice, repo: start_repo(alice.did)}
  end

  test "the reaper is running under the application supervisor" do
    assert is_pid(Process.whereis(Pesque.EventReaper))
  end

  test "a sweep drops aged events and unreachable blocks, and keeps the rest", ctx do
    {:ok, _} = RepoServer.create_record(ctx.repo, "app.bsky.feed.post", "1", post("one"))

    RepoStore.insert_blocks!(ctx.alice.did, %{("bafyreiorphan" <> unique("x")) => <<1, 2, 3>>})

    age_all_events()

    before_blocks = RepoStore.block_count(ctx.alice.did)

    Pesque.EventReaper.sweep()

    assert Repo.aggregate(Event, :count) == 0

    after_blocks = RepoStore.block_count(ctx.alice.did)

    assert after_blocks < before_blocks
    assert RepoStore.get_record(ctx.alice.did, "app.bsky.feed.post", "1")
    assert RepoStore.get_block(ctx.alice.did, RepoStore.get_meta("root:" <> ctx.alice.did))
    assert RepoStore.get_block(ctx.alice.did, RepoStore.get_meta("commit:" <> ctx.alice.did))
  end

  defp age_all_events do
    old = DateTime.add(DateTime.utc_now(), -8, :day) |> DateTime.truncate(:second)
    Repo.update_all(Event, set: [inserted_at: old])
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
