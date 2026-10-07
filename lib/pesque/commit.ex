defmodule Pesque.Commit do
  @moduledoc """
  The pure commit protocol: everything between a validated write and the
  bytes that get stored and streamed. MST update, DAG-CBOR encoding,
  secp256k1 signing, CAR encoding, and the result map a write answers
  with. No database, no processes: the RepoServer owns the state, the
  transaction, and the registry fan-out.

  The tree is updated incrementally against the root CID in state, reading only
  the nodes a change rewrites. A tree that cannot be walked falls back to a
  rebuild from the entry map, and `mst` in the result says which happened so the
  caller can log the fallback.

  The seq number and the block set a frame carries can only be known
  inside that transaction, so the protocol runs in two steps: commit/2
  turns the current entries/rev/tid plus writes into the new
  entries/rev/tid, the commit's CIDs and blocks, and the result map, and
  frames/4 turns that plus the claimed seq and the blocks the transaction
  will actually insert into the frames the stream puts out.
  """

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Car
  alias Pesque.Lexicon
  alias Pesque.Mst
  alias Pesque.Secp256k1
  alias Pesque.Tid

  # The lexicon's own limits on a #commit diff. Over either one the diff does
  # not fit in a frame, so the frame says so and the #sync behind it is what
  # tells a consumer to re-fetch the repo instead of applying the diff.
  @max_blocks_bytes 2_000_000
  @max_ops 200

  @doc """
  Encodes one checked record into the change a commit consumes.

  from_json/1 is what turns a client's $link and $bytes into the
  structures CBOR understands, and it is the last point at which a bad
  value can be turned away: past it the encoder raises rather than
  answering a tuple.
  """
  def encode_write(entries, action, key, record) do
    case Lexicon.from_json(record) do
      {:ok, internal} ->
        data = CBOR.encode(internal)
        cid = CID.from_data(data)
        action = write_action(action, entries, key)

        {:ok,
         %{
           action: action,
           key: key,
           cid: cid,
           data: data,
           prev_cid: if(action == "create", do: nil, else: Map.fetch!(entries, key))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs the protocol over `changes` and returns the new entries/rev/tid
  plus everything the transaction and the frame need: root and commit
  CIDs, every block the commit creates, and the result map.

  `commit_cid` is the head this commit follows, which becomes its `prev`. It
  is nil for the genesis commit, and the commit object carries `prev: null`
  then, since the schema requires the field to be present.
  """
  def commit(
        %{
          did: did,
          clock_id: clock_id,
          priv: priv,
          entries: entries,
          rev: prev_rev,
          tid_int: tid_int,
          commit_cid: prev_commit,
          root_cid: prev_root
        } = state,
        changes
      ) do
    entries2 =
      Enum.reduce(changes, entries, fn
        %{action: "delete", key: key}, acc -> Map.delete(acc, key)
        %{key: key, cid: cid}, acc -> Map.put(acc, key, cid)
      end)

    {root_cid, node_blocks, mst} = apply_mst(state, entries2, changes)
    {rev, tid_int} = Tid.next(tid_int, clock_id)

    unsigned = %{
      "did" => did,
      "version" => 3,
      "data" => root_cid,
      "rev" => rev,
      "prev" => prev_commit
    }

    sig = Secp256k1.sign(priv, CBOR.encode(unsigned))
    commit_obj = Map.put(unsigned, "sig", %CBOR.Bytes{data: sig})
    commit_bytes = CBOR.encode(commit_obj)
    commit_cid = CID.from_data(commit_bytes)

    all_blocks =
      node_blocks
      |> Map.merge(Map.new(for %{cid: cid, data: data} <- changes, data != nil, do: {cid, data}))
      |> Map.put(commit_cid, commit_bytes)

    result = %{
      "commit" => %{"cid" => CID.to_string(commit_cid), "rev" => rev},
      "changes" =>
        Enum.map(changes, fn c ->
          %{
            "uri" => "at://" <> did <> "/" <> c.key,
            "cid" => if(c.cid, do: CID.to_string(c.cid)),
            "action" => c.action
          }
        end)
    }

    {:ok,
     %{
       did: did,
       prev_rev: prev_rev,
       entries: entries2,
       rev: rev,
       tid_int: tid_int,
       root_cid: root_cid,
       prev_root: prev_root,
       commit_cid: commit_cid,
       all_blocks: all_blocks,
       mst: mst,
       result: result
     }}
  end

  # The tree as stored, not as rebuilt. Only the nodes a change rewrites are
  # read, so a write costs the depth of the tree. A tree that cannot be walked
  # (a missing or corrupt node) is rebuilt from the entry map, and the caller
  # logs that: a silent rebuild would hide a storage problem behind correct
  # output, which is the one way this fallback can go wrong.
  defp apply_mst(%{root_cid: nil}, entries, _changes), do: build(entries, :genesis)

  defp apply_mst(%{root_cid: root, fetch: fetch}, entries, changes) when is_function(fetch, 1) do
    ops =
      Enum.map(changes, fn
        %{action: "delete", key: key} -> {:delete, key}
        %{key: key, cid: cid} -> {:put, key, cid}
      end)

    case Mst.update_tree(root, ops, fetch) do
      {:ok, {new_root, blocks}} ->
        {new_root, blocks, :incremental}

      {:error, reason} ->
        build(entries, {:rebuild, reason})
    end
  end

  defp build(entries, path) do
    {root, blocks} = Mst.build(entries)
    {root, blocks, path}
  end

  @doc """
  The firehose frames one commit puts on the stream, as `{seq, frame}` pairs
  in the order they go out.

  The first is always the `#commit` envelope over the CAR of the blocks this
  frame carries. `blocks` is the commit's whole block map, keyed by `%CID{}`,
  and `already` is the CID strings storage already holds; the frame carries the
  blocks that are not in `already`, which is the set this commit added rather
  than the whole commit closure, because a frame sized to the closure reports
  `tooBig` forever on a repo past the blocks limit. Storage does not depend on
  it, so a block that is in the frame or not is written either way.

  A commit whose CAR is over the lexicon's 2,000,000-byte `blocks` limit, or
  whose op count is over its limit of 200, is over what a consumer is meant to
  apply in one frame. Those go out as `#commit` with `tooBig: true`, followed by
  a `#sync` carrying the same commit and nothing else: the consumer cannot apply
  the diff, so the sync tells it the repo moved and to re-fetch it wholesale.
  The seq of the sync follows the seq of the commit it recovers, and both are
  claimed inside the same transaction.

  This is the only place the server emits `#sync`. A cursor gap is a `#info`
  `OutdatedCursor`, which already says the consumer is behind, and every write
  here is a commit with a diff, so there is no repo update without one.
  """
  def frames(
        %{
          did: did,
          prev_rev: prev_rev,
          rev: rev,
          commit_cid: commit_cid,
          prev_root: prev_root
        } = prepared,
        seq,
        blocks,
        already,
        changes
      ) do
    new_blocks =
      blocks
      |> Enum.reject(fn {cid, _bytes} -> MapSet.member?(already, CID.to_string(cid)) end)
      |> Map.new()

    car = Car.encode([commit_cid], new_blocks)

    ops =
      Enum.map(changes, fn c ->
        op = %{"action" => c.action, "path" => c.key, "cid" => c.cid}
        if c.action == "create", do: op, else: Map.put(op, "prev", c.prev_cid)
      end)

    too_big = byte_size(car) > @max_blocks_bytes or length(ops) > @max_ops
    time = now()

    body =
      with_prev_data(
        %{
          "seq" => seq,
          "rebase" => false,
          "tooBig" => too_big,
          "repo" => did,
          "commit" => commit_cid,
          "rev" => rev,
          "since" => prev_rev,
          "blocks" => %CBOR.Bytes{data: car},
          "ops" => ops,
          "blobs" => [],
          "time" => time
        },
        prev_root
      )

    commit =
      {seq, CBOR.encode(%{"op" => 1, "t" => "#commit"}) <> CBOR.encode(body)}

    if too_big do
      [commit, sync_frame(prepared, seq + 1, time)]
    else
      [commit]
    end
  end

  # prevData is the previous commit's MST root, which is the field the
  # inductive firehose applies its diff on top of. A genesis commit has no
  # previous root and the lexicon does not mark the field nullable, so it is
  # absent rather than null.
  defp with_prev_data(body, nil), do: body
  defp with_prev_data(body, prev_root), do: Map.put(body, "prevData", prev_root)

  defp sync_frame(
         %{did: did, rev: rev, commit_cid: commit_cid, all_blocks: all_blocks},
         seq,
         time
       ) do
    commit_bytes = Map.fetch!(all_blocks, commit_cid)

    {seq,
     CBOR.encode(%{"op" => 1, "t" => "#sync"}) <>
       CBOR.encode(%{
         "seq" => seq,
         "did" => did,
         "blocks" => %CBOR.Bytes{data: Car.encode([commit_cid], %{commit_cid => commit_bytes})},
         "rev" => rev,
         "time" => time
       })}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp write_action(:create, _entries, _key), do: "create"

  defp write_action(:put, entries, key),
    do: if(Map.has_key?(entries, key), do: "update", else: "create")
end
