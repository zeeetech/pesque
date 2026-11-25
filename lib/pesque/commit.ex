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

  The seq number can only be known inside that transaction, so the protocol
  runs in two steps: commit/2 prepares the new entries/rev/tid, CIDs, blocks,
  and result map, and frame/3 validates and encodes the firehose event. The
  CAR is a self-contained diff: it includes every block a consumer needs even
  when storage already holds the CID, as happens when a record is recreated.
  """

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Car
  alias Pesque.Lexicon
  alias Pesque.Mst
  alias Pesque.Secp256k1
  alias Pesque.Tid

  @max_record_bytes 1_000_000
  @max_blocks_bytes 2_000_000
  @max_ops 200
  @max_frame_bytes 5_000_000

  def max_record_bytes, do: @max_record_bytes
  def max_blocks_bytes, do: @max_blocks_bytes
  def max_ops, do: @max_ops
  def max_frame_bytes, do: @max_frame_bytes

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

        if byte_size(data) > @max_record_bytes do
          {:error, :record_too_large}
        else
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
        end

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
  Builds one validated `#commit` frame. The CAR carries the blocks produced by
  this commit, including record blocks that storage may already have held.

  Returns `{:ok, {seq, binary}}`, or `{:error, reason}` with `:too_many_ops`,
  `:record_too_large`, `:commit_too_large`, or `:frame_too_large`.
  """
  def frame(
        %{
          did: did,
          prev_rev: prev_rev,
          rev: rev,
          commit_cid: commit_cid,
          prev_root: prev_root,
          all_blocks: all_blocks
        },
        seq,
        changes
      ) do
    car = Car.encode([commit_cid], all_blocks)

    ops =
      Enum.map(changes, fn c ->
        op = %{"action" => c.action, "path" => c.key, "cid" => c.cid}
        if c.action == "create", do: op, else: Map.put(op, "prev", c.prev_cid)
      end)

    body =
      with_prev_data(
        %{
          "seq" => seq,
          "rebase" => false,
          "tooBig" => false,
          "repo" => did,
          "commit" => commit_cid,
          "rev" => rev,
          "since" => prev_rev,
          "blocks" => %CBOR.Bytes{data: car},
          "ops" => ops,
          "blobs" => [],
          "time" => now()
        },
        prev_root
      )

    frame = {seq, CBOR.encode(%{"op" => 1, "t" => "#commit"}) <> CBOR.encode(body)}

    cond do
      length(ops) > @max_ops -> {:error, :too_many_ops}
      Enum.any?(changes, &oversized_record?/1) -> {:error, :record_too_large}
      byte_size(car) > @max_blocks_bytes -> {:error, :commit_too_large}
      byte_size(elem(frame, 1)) > @max_frame_bytes -> {:error, :frame_too_large}
      true -> {:ok, frame}
    end
  end

  defp oversized_record?(%{data: data}),
    do: is_binary(data) and byte_size(data) > @max_record_bytes

  # prevData is the previous commit's MST root, which is the field the
  # inductive firehose applies its diff on top of. A genesis commit has no
  # previous root and the lexicon does not mark the field nullable, so it is
  # absent rather than null.
  defp with_prev_data(body, nil), do: body
  defp with_prev_data(body, prev_root), do: Map.put(body, "prevData", prev_root)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp write_action(:create, _entries, _key), do: "create"

  defp write_action(:put, entries, key),
    do: if(Map.has_key?(entries, key), do: "update", else: "create")
end
