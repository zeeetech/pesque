defmodule PesqueWeb.CommitFramesTest do
  @moduledoc """
  What one commit puts on the wire: the chain its commit object names, and the
  frames a consumer reads it from.

  Two claims are pinned here that a mirror would otherwise take on trust. The
  commit object names the commit before it, so history can be walked back from
  a head without asking this server anything, and the signature covers that
  `prev` along with everything else. And a commit too big to apply in one frame
  says so and is followed by the `#sync` that tells a consumer to re-fetch.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.CBOR
  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.Keys
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.Secp256k1

  setup do
    alice = create_account("alice")
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(alice.did)

    %{alice: alice, pid: pid}
  end

  # prev is the field a consumer walks history back from, so it is a CID of a
  # commit this server actually signed rather than a value that merely looks
  # right. Reading it off the stored block is what a mirror would see.
  test "a second commit's prev names the commit before it", ctx do
    genesis = head(ctx.alice.did)

    {:ok, _} = write(ctx, "1", "first")
    first = head(ctx.alice.did)

    {:ok, _} = write(ctx, "2", "second")

    refute first == genesis
    assert CID.to_string(commit(ctx.alice.did)["prev"]) == first
    assert head(ctx.alice.did) != first
  end

  # prev arrives from meta, not from a process that may have died. A repo that
  # restarts between two commits has to chain the way one that never stopped
  # does, or the chain breaks at every deploy.
  test "prev survives a repo restart", ctx do
    {:ok, _} = write(ctx, "1", "first")
    before = head(ctx.alice.did)

    stopped = await_stopped(ctx.pid, ctx.alice.did)
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(ctx.alice.did)
    RepoServer.entries(pid)

    refute pid == stopped
    assert {:ok, _} = RepoServer.create_record(pid, collection(), "2", post_record("second"))

    assert CID.to_string(commit(ctx.alice.did)["prev"]) == before
  end

  # The genesis commit has nothing behind it. The field is present and null
  # rather than absent, because the schema requires it in the CBOR object.
  test "the genesis commit has no prev", ctx do
    genesis = commit(ctx.alice.did)

    assert genesis["prev"] == nil
    assert genesis["did"] == ctx.alice.did
    assert genesis["version"] == 3
  end

  # prev is inside the signed bytes, so a mirror checks it the same way it
  # checks the rev. If it were not, a server could rewrite history without
  # invalidating the signature.
  test "the signature covers the commit object with prev present", ctx do
    {:ok, _} = write(ctx, "1", "first")
    {:ok, _} = write(ctx, "2", "second")

    object = commit(ctx.alice.did)

    refute is_nil(object["prev"])
    assert verifies?(ctx.alice, object)

    without_prev = object |> Map.delete("prev") |> Map.delete("sig") |> CBOR.encode()
    refute verifies?(ctx.alice, object, without_prev)
  end

  # The read paths a consumer can reach the same commit through. They have to
  # agree with each other and with what the firehose announced, or a mirror
  # fetching a head the stream already told it about gets a different repo.
  test "getLatestCommit, getRepo and the firehose frame name the same commit", ctx do
    cursor = RepoStore.max_seq()
    {:ok, _} = write(ctx, "1", "first")

    cid = head(ctx.alice.did)
    rev = rev_meta(ctx.alice.did)

    latest = xrpc_get("/xrpc/com.atproto.sync.getLatestCommit?did=#{enc(ctx.alice.did)}")
    assert JSON.decode!(latest.resp_body) == %{"cid" => cid, "rev" => rev}

    {roots, blocks} =
      "/xrpc/com.atproto.sync.getRepo?did=#{enc(ctx.alice.did)}"
      |> xrpc_get()
      |> Map.fetch!(:resp_body)
      |> Car.decode()

    assert roots == [CID.parse(cid)]
    assert CBOR.decode!(blocks[CID.parse(cid)]) == commit(ctx.alice.did)

    assert [{_, frame}] = decode(RepoStore.events_after(cursor))
    assert frame["commit"] == CID.parse(cid)
    assert frame["rev"] == rev
    assert frame["tooBig"] == false
  end

  # The commit block leads the CAR: a consumer handed a slice has to be able to
  # tell which repo version it is holding without trusting the request.
  test "the commit CAR leads with the commit CID in its roots", ctx do
    {:ok, _} = write(ctx, "1", "first")

    assert [{_, frame}] = decode(RepoStore.events_after(RepoStore.max_seq() - 1))
    {roots, blocks} = Car.decode(frame["blocks"].data)

    assert roots == [frame["commit"]]
    assert Map.has_key?(blocks, frame["commit"])
  end

  # Over the lexicon's limits the diff is not something a consumer can apply in
  # one frame. The #commit says so with tooBig, and the #sync behind it carries
  # the commit alone: the repo is at this rev, re-fetch it.
  test "an oversized commit is tooBig and is followed by a #sync carrying the commit", ctx do
    cursor = RepoStore.max_seq()

    {:ok, _} = RepoServer.apply_writes(ctx.pid, bulk_writes(201))

    assert [{commit_header, commit_body}, {sync_header, sync_body}] =
             decode(RepoStore.events_after(cursor))

    assert commit_header == %{"op" => 1, "t" => "#commit"}
    assert sync_header == %{"op" => 1, "t" => "#sync"}

    assert commit_body["tooBig"] == true
    assert length(commit_body["ops"]) == 201

    assert sync_body["seq"] == commit_body["seq"] + 1
    assert sync_body["did"] == ctx.alice.did
    assert sync_body["rev"] == commit_body["rev"]

    # The sync carries the commit and nothing else, rooted at it, which is what
    # lets a consumer read it as "the repo moved, re-fetch it" rather than as a
    # diff it could try to apply.
    {roots, blocks} = Car.decode(sync_body["blocks"].data)
    commit_cid = commit_body["commit"]

    assert roots == [commit_cid]
    assert map_size(blocks) == 1
    assert CBOR.decode!(blocks[commit_cid])["rev"] == sync_body["rev"]
  end

  # The recovery frame has to survive the cursor, or a consumer reconnecting in
  # the middle of a bulk write sees a #commit it cannot apply and no frame
  # telling it what to do about it.
  test "the #sync of an oversized commit replays from a cursor", ctx do
    cursor = RepoStore.max_seq()
    {:ok, _} = RepoServer.apply_writes(ctx.pid, bulk_writes(201))

    assert {:push, [{:binary, replayed_commit}, {:binary, replayed_sync}], _state} =
             PesqueWeb.Firehose.init(%{cursor: cursor})

    assert [{%{"t" => "#commit"}, _}, {%{"t" => "#sync"}, _}] =
             decode([replayed_commit, replayed_sync])
  end

  # A commit inside the limits is a single #commit. A #sync on every write would
  # make every consumer re-fetch every repo on the server.
  test "a commit inside the limits emits no #sync", ctx do
    cursor = RepoStore.max_seq()

    {:ok, _} = write(ctx, "1", "hello")

    assert [{header, body}] = decode(RepoStore.events_after(cursor))
    assert header == %{"op" => 1, "t" => "#commit"}
    assert body["tooBig"] == false
  end

  # terminate_child returns once the supervisor has stopped the child, but the
  # registry entry for that pid goes with the process rather than before it, so
  # ensure_started/1 called straight after can hand back the pid that is on its
  # way out. Waiting for the DOWN is what makes this a restart rather than a
  # call to a process nobody is supervising any more.
  defp await_stopped(pid, did) do
    ref = Process.monitor(pid)
    assert {:ok, :stopped} = RepoServer.stop(did)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp bulk_writes(count) do
    for i <- 1..count do
      %{
        "$type" => "com.atproto.repo.applyWrites#create",
        "collection" => collection(),
        "rkey" => "r#{i}",
        "value" => post_record("bulk #{i}")
      }
    end
  end

  defp write(ctx, rkey, text),
    do: RepoServer.create_record(ctx.pid, collection(), rkey, post_record(text))

  defp rev_meta(did), do: RepoStore.get_meta("rev:" <> did)

  defp head(did), do: RepoStore.get_meta("commit:" <> did)

  defp commit(did) do
    did
    |> RepoStore.get_block(head(did))
    |> Map.fetch!(:data)
    |> CBOR.decode!()
  end

  defp verifies?(alice, object, payload \\ nil) do
    payload = payload || object |> Map.delete("sig") |> CBOR.encode()
    {:ok, key} = Keys.ensure(alice.did)

    :crypto.verify(
      :ecdsa,
      :sha256,
      payload,
      Secp256k1.raw_to_der(object["sig"].data),
      [key.pub, :secp256k1]
    )
  end

  defp decode(frames) do
    Enum.map(frames, fn frame ->
      {header, rest} = CBOR.decode(frame)
      {body, ""} = CBOR.decode(rest)
      {header, body}
    end)
  end
end
