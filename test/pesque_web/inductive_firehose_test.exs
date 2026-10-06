defmodule PesqueWeb.InductiveFirehoseTest do
  @moduledoc """
  The inductive firehose fields: the previous tree root a #commit carries as
  `prevData`, and the previous record CID a repoOp carries as `prev`.

  Both are frame-level metadata. They describe the diff a consumer applies on
  top of the state it already holds, and neither is part of the signed commit
  object, so the commit CID is the hash of the object alone.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.CBOR
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

  test "a create op carries no prev", ctx do
    cursor = RepoStore.max_seq()
    {:ok, _} = create(ctx, "one", "first")

    assert [op] = ops_since(cursor, ctx.alice.did)
    assert op["action"] == "create"
    refute Map.has_key?(op, "prev")
  end

  test "an update op's prev is the old record CID and its cid is the new one", ctx do
    {:ok, _} = create(ctx, "one", "first")
    old = entry(ctx, "one")
    cursor = RepoStore.max_seq()

    {:ok, _} = RepoServer.put_record(ctx.pid, collection(), "one", post_record("second"))

    assert [op] = ops_since(cursor, ctx.alice.did)
    assert op["action"] == "update"
    assert op["prev"] == old
    refute op["cid"] == old
  end

  test "a delete op's prev is the old CID and its cid is null", ctx do
    {:ok, _} = create(ctx, "one", "first")
    old = entry(ctx, "one")
    cursor = RepoStore.max_seq()

    {:ok, _} = RepoServer.delete_record(ctx.pid, collection(), "one")

    assert [op] = ops_since(cursor, ctx.alice.did)
    assert op["action"] == "delete"
    assert op["prev"] == old
    assert op["cid"] == nil
  end

  test "a commit's prevData is the previous commit's data root", ctx do
    {:ok, _} = create(ctx, "one", "first")
    first = commit_object(ctx.alice.did)

    cursor = RepoStore.max_seq()
    {:ok, _} = create(ctx, "two", "second")

    assert [body] = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)
    assert body["prevData"] == first["data"]
  end

  # The genesis commit has no previous root, and the lexicon does not mark
  # prevData nullable, so the field is absent rather than null. That matches
  # the reference encoder, which strips undefined properties.
  test "the genesis commit carries no prevData", ctx do
    assert [body] = commit_bodies(RepoStore.events_after(0), ctx.alice.did)
    assert body["since"] == nil
    refute Map.has_key?(body, "prevData")
  end

  # prevData is read from the root in state, which is loaded from meta, so a
  # repo that restarts between two commits chains the same way one that never
  # stopped does.
  test "prevData survives a repo restart", ctx do
    {:ok, _} = create(ctx, "one", "first")
    first = commit_object(ctx.alice.did)

    stopped = await_stopped(ctx.pid, ctx.alice.did)
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(ctx.alice.did)
    RepoServer.entries(pid)

    refute pid == stopped
    cursor = RepoStore.max_seq()
    {:ok, _} = RepoServer.create_record(pid, collection(), "two", post_record("second"))

    assert [body] = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)
    assert body["prevData"] == first["data"]
  end

  # A batch is prepared against a running view of the entry map, so the update
  # sees the CID the create in the same batch produced rather than the head the
  # batch started from.
  test "a batch that creates then updates one key carries the create's CID as prev", ctx do
    cursor = RepoStore.max_seq()

    writes = [
      create_write("chained", "first"),
      update_write("chained", "second")
    ]

    assert {:ok, _} = RepoServer.apply_writes(ctx.pid, writes)

    assert [body] = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)
    assert [created, updated] = body["ops"]
    assert created["action"] == "create"
    refute Map.has_key?(created, "prev")
    assert updated["action"] == "update"
    assert updated["prev"] == created["cid"]
    refute updated["cid"] == created["cid"]
  end

  test "a batch that creates then deletes one key carries the create's CID as prev", ctx do
    cursor = RepoStore.max_seq()

    writes = [
      create_write("chained", "first"),
      delete_write("chained")
    ]

    assert {:ok, _} = RepoServer.apply_writes(ctx.pid, writes)

    assert [body] = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)
    assert [created, deleted] = body["ops"]
    refute Map.has_key?(created, "prev")
    assert deleted["action"] == "delete"
    assert deleted["prev"] == created["cid"]
    assert deleted["cid"] == nil
  end

  test "a replayed frame carries the same inductive fields", ctx do
    cursor = RepoStore.max_seq()
    {:ok, _} = create(ctx, "one", "first")
    {:ok, _} = RepoServer.put_record(ctx.pid, collection(), "one", post_record("second"))
    {:ok, _} = RepoServer.delete_record(ctx.pid, collection(), "one")

    stored = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)

    assert {:push, pushed, _state} = PesqueWeb.Firehose.init(%{cursor: cursor})

    replayed =
      pushed
      |> Enum.map(fn {:binary, frame} -> frame end)
      |> commit_bodies(ctx.alice.did)

    assert replayed == stored
  end

  # prevData and per-op prev are frame metadata, so the commit object is the
  # same six fields it always was and its CID is the hash of those bytes alone.
  test "the commit object does not carry the frame fields", ctx do
    cursor = RepoStore.max_seq()
    {:ok, _} = create(ctx, "one", "first")

    assert [body] = commit_bodies(RepoStore.events_after(cursor), ctx.alice.did)
    commit_cid = body["commit"]

    bytes = Map.fetch!(RepoStore.get_block(ctx.alice.did, CID.to_string(commit_cid)), :data)
    object = CBOR.decode!(bytes)

    assert object |> Map.keys() |> Enum.sort() == ~w(data did prev rev sig version)
    refute Map.has_key?(object, "prevData")

    assert CID.from_data(bytes) == commit_cid
    assert verifies?(ctx.alice, object)
  end

  defp create(ctx, rkey, text),
    do: RepoServer.create_record(ctx.pid, collection(), rkey, post_record(text))

  defp create_write(rkey, text) do
    %{
      "$type" => "com.atproto.repo.applyWrites#create",
      "collection" => collection(),
      "rkey" => rkey,
      "value" => post_record(text)
    }
  end

  defp update_write(rkey, text) do
    %{
      "$type" => "com.atproto.repo.applyWrites#update",
      "collection" => collection(),
      "rkey" => rkey,
      "value" => post_record(text)
    }
  end

  defp delete_write(rkey) do
    %{
      "$type" => "com.atproto.repo.applyWrites#delete",
      "collection" => collection(),
      "rkey" => rkey
    }
  end

  defp entry(ctx, rkey),
    do: ctx.pid |> RepoServer.entries() |> Map.fetch!(collection() <> "/" <> rkey)

  defp head(did), do: RepoStore.get_meta("commit:" <> did)

  defp commit_object(did) do
    did
    |> RepoStore.get_block(head(did))
    |> Map.fetch!(:data)
    |> CBOR.decode!()
  end

  defp ops_since(cursor, did) do
    cursor
    |> RepoStore.events_after()
    |> commit_bodies(did)
    |> Enum.flat_map(& &1["ops"])
  end

  defp commit_bodies(frames, did) do
    frames
    |> Enum.map(&decode/1)
    |> Enum.filter(fn {_header, body} -> body["repo"] == did end)
    |> Enum.map(&elem(&1, 1))
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end

  # terminate_child returns once the supervisor has stopped the child, but the
  # registry entry for that pid goes with the process rather than before it, so
  # waiting for the DOWN is what makes this a restart rather than a call to a
  # process nobody is supervising any more.
  defp await_stopped(pid, did) do
    ref = Process.monitor(pid)
    assert {:ok, :stopped} = RepoServer.stop(did)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp verifies?(alice, object) do
    payload = object |> Map.delete("sig") |> CBOR.encode()
    {:ok, key} = Keys.ensure(alice.did)

    :crypto.verify(
      :ecdsa,
      :sha256,
      payload,
      Secp256k1.raw_to_der(object["sig"].data),
      [key.pub, :secp256k1]
    )
  end
end
