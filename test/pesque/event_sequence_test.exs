defmodule Pesque.EventSequenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.{CBOR, Repo, RepoStore, RepoServer, Tid}
  alias Pesque.RepoStore.Event

  setup do
    Pesque.DataCase.setup()

    # Seeding rev and tid_int skips the genesis commit, so both RepoServers
    # snapshot the same max_seq, with no event written in between.
    carol = repo("carol")
    dave = repo("dave")

    %{carol: carol, dave: dave}
  end

  test "interleaved commits from two repos get a shared, gap-free sequence", %{
    carol: carol,
    dave: dave
  } do
    pid_carol = start_repo(carol)
    pid_dave = start_repo(dave)

    before = RepoStore.max_seq()

    {:ok, _} = RepoServer.create_record(pid_carol, "app.bsky.feed.post", "1", post("1"))
    {:ok, _} = RepoServer.create_record(pid_dave, "app.bsky.feed.post", "1", post("2"))
    {:ok, _} = RepoServer.create_record(pid_carol, "app.bsky.feed.post", "2", post("3"))
    {:ok, _} = RepoServer.create_record(pid_dave, "app.bsky.feed.post", "2", post("4"))

    assert events(before) == Enum.to_list((before + 1)..(before + 4))
    assert dids(before) == [carol, dave, carol, dave]

    for event <- Repo.all(from e in Event, where: e.seq > ^before, order_by: e.seq) do
      {_header, rest} = CBOR.decode(event.payload)
      {%{"seq" => seq, "repo" => did}, _rest} = CBOR.decode(rest)

      assert seq == event.seq
      assert did == event.did
    end
  end

  defp repo(name) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    did = "did:web:localhost:user:" <> name <> suffix
    {rev, _} = Tid.next(0, 0)

    RepoStore.put_meta!("rev:" <> did, rev)
    RepoStore.put_meta!("tid_int:" <> did, "0")

    did
  end

  defp start_repo(did) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(did)
    RepoServer.entries(pid)
    pid
  end

  defp events(after_seq) do
    Repo.all(from e in Event, where: e.seq > ^after_seq, order_by: e.seq, select: e.seq)
  end

  defp dids(after_seq) do
    Repo.all(from e in Event, where: e.seq > ^after_seq, order_by: e.seq, select: e.did)
  end

  defp post(text) do
    %{"$type" => "app.bsky.feed.post", "text" => text, "createdAt" => "2026-01-01T00:00:00.000Z"}
  end
end
