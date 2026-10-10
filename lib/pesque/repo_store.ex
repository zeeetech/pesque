defmodule Pesque.RepoStore do
  @moduledoc "All SQL for the repository layer lives here."

  import Ecto.Query

  require Logger

  alias Pesque.CID
  alias Pesque.Mst
  alias Pesque.Repo
  alias Pesque.RepoStore.Blob
  alias Pesque.RepoStore.Block
  alias Pesque.RepoStore.Event
  alias Pesque.RepoStore.Meta
  alias Pesque.RepoStore.Record

  # A statement may bind at most SQLITE_MAX_VARIABLE_NUMBER parameters (32766 on
  # the SQLite exqlite bundles), and insert_all binds one per column per row. A
  # migration writes a whole repo's blocks in one call, tens of thousands of
  # them, so the rows go in batches that stay well under the ceiling.
  @blocks_per_insert 2_000

  # records

  def records_for(did) do
    Repo.all(
      from r in Record,
        where: r.did == ^did,
        select: %{collection: r.collection, rkey: r.rkey, cid: r.cid}
    )
  end

  def get_record(did, collection, rkey) do
    Repo.get_by(Record, did: did, collection: collection, rkey: rkey)
  end

  @doc """
  A stored block by CID, whatever collection or key wrote it.

  This is what a getRecord carrying a cid answers from: a superseded version
  was replaced in `records`, but the block it was stored as is still here
  until sweep_blocks!/1 collects it, which a later commit made unreachable.
  """
  def get_block(did, cid_string) do
    Repo.get_by(Block, did: did, cid: cid_string)
  end

  @doc """
  Reads one block's bytes by CID, in the shape the MST walk fetches nodes with.

  A block this repo does not hold is `{:error, {:missing_block, cid}}` rather
  than nil, because the walk cannot tell the difference between "no such node"
  and "not stored here" and must not guess.
  """
  def fetch_block(did, %CID{} = cid) do
    case get_block(did, CID.to_string(cid)) do
      %Block{data: data} -> {:ok, data}
      nil -> {:error, {:missing_block, CID.to_string(cid)}}
    end
  end

  @doc "A `fetch_block/2` closure for one repo, the shape `Pesque.Mst.update_tree/3` takes."
  def block_fetcher(did), do: fn cid -> fetch_block(did, cid) end

  def list_records(did, collection, limit, offset, reverse) do
    dir = if reverse, do: :desc, else: :asc

    Repo.all(
      from r in Record,
        where: r.did == ^did and r.collection == ^collection,
        order_by: [{^dir, r.rkey}],
        limit: ^limit,
        offset: ^offset
    )
  end

  def collections_for(did) do
    Repo.all(from r in Record, where: r.did == ^did, distinct: true, select: r.collection)
  end

  def put_record!(did, collection, rkey, cid, data) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert!(
      %Record{
        did: did,
        collection: collection,
        rkey: rkey,
        cid: cid,
        data: data,
        inserted_at: now
      },
      on_conflict: {:replace, [:cid, :data]},
      conflict_target: [:did, :collection, :rkey]
    )
  end

  def delete_record!(did, collection, rkey) do
    Repo.delete!(%Record{did: did, collection: collection, rkey: rkey})
  end

  @doc """
  Every record of `did` with its bytes, for a caller that has to read the
  record values rather than only their keys.
  """
  def records_with_data(did) do
    Repo.all(
      from r in Record,
        where: r.did == ^did,
        select: %{collection: r.collection, rkey: r.rkey, data: r.data}
    )
  end

  @doc """
  Deletes every record of `did`. The import path replaces a repo wholesale, so
  it clears the rows first rather than leaving behind keys the import did not
  carry.
  """
  def delete_records!(did) do
    Repo.delete_all(from r in Record, where: r.did == ^did)
  end

  # blocks

  def blocks_for(did) do
    Repo.all(from b in Block, where: b.did == ^did)
  end

  @doc """
  Every block of `did`, keyed by CID string.

  What the CAR endpoints and the sweep both need from the table, so the
  keying is written once.
  """
  def blocks_map(did) do
    Map.new(blocks_for(did), &{&1.cid, &1.data})
  end

  @doc """
  Every CID of `did`, without the bytes behind them.

  A CAR stream has to know the whole block order before it writes the header,
  and a block order is the set of CIDs, not the set of payloads. Selecting only
  the CID column is what lets getRepo decide its whole answer up front and then
  read the bytes a batch at a time; blocks_map/1 here would defeat that by
  pulling the repo in first.
  """
  def block_cids(did) do
    Repo.all(from b in Block, where: b.did == ^did, select: b.cid)
  end

  @doc """
  Which of `cid_strings` this repo already holds.

  Used to pick the incremental block set a `#commit` frame carries, so a frame
  stays proportional to what the commit added rather than to the size of the
  commit's closure. It is deliberately not used to decide what to insert: the
  insert is unconditional, so nothing about a block's storage correctness
  depends on having read this first.
  """
  def existing_cids(did, cid_strings) do
    cid_strings
    # Chunked well under SQLite's bound-variable ceiling, not a tuning knob.
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from b in Block, where: b.did == ^did and b.cid in ^chunk, select: b.cid)
    end)
    |> MapSet.new()
  end

  @doc """
  The stored blocks `cid_strings` names, keyed by CID string.

  A CID this repo does not hold is absent from the map rather than nil: a
  block either exists or it does not, and the caller is the one that decides
  what a missing one means. Chunked well under SQLite's bound-variable ceiling,
  not a tuning knob.
  """
  def blocks_by_cids(did, cid_strings) do
    cid_strings
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from b in Block, where: b.did == ^did and b.cid in ^chunk, select: {b.cid, b.data})
    end)
    |> Map.new()
  end

  @doc """
  The blocks a consumer needs to place `cid_string` in this repo: the MST nodes
  from the current root down to the one holding its entry, plus the block
  itself.

  The record block alone does not say where it lives. Reaching it from the root
  is what turns a hash into a position, so the walk follows the same child
  links sweep_blocks!/1 follows and a tree it cannot finish answers an error
  rather than a partial path.

  Answers {:error, :no_root} when the repo has no commit, {:error, :not_found}
  when the tree does not name the block at all, and {:error, :corrupt} when a
  block on the way is missing or does not decode.
  """
  def blocks_for_path(did, cid_string) do
    case get_meta("root:" <> did) do
      nil -> {:error, :no_root}
      root -> Mst.blocks_for_path(blocks_map(did), root, cid_string)
    end
  end

  # A count, not a length. blocks_for/1 selects the block bytes, and a status
  # endpoint that answered from it would pull a whole repo into memory to
  # report how big it is.
  def block_count(did) do
    Repo.one(from b in Block, where: b.did == ^did, select: count(b.cid)) || 0
  end

  @doc """
  Deletes every block of `did` the current MST cannot reach.

  The head commit, the record CIDs the tree points at, and every MST node on
  the way down are reachable and kept. The head commit block in particular is
  not in the tree at all, it is only named by the meta rows, so it is marked
  by hand.

  A tree the walk cannot finish is not swept at all. A block the tree names
  that is missing, or whose bytes do not decode, means the walk cannot say what
  hangs below it, and everything below it would look unreachable. Deleting on
  an incomplete walk is how a repo loses records a reader can still ask for by
  CID, so the answer is to delete nothing and answer 0.

  Answers the number of rows deleted.
  """
  def sweep_blocks!(did) do
    blocks = blocks_map(did)

    case get_meta("root:" <> did) do
      nil ->
        0

      root ->
        walk(MapSet.new([get_meta("commit:" <> did)]), blocks, [root], did)
    end
  end

  defp walk(marked, blocks, [cid | queue], did) do
    cond do
      MapSet.member?(marked, cid) ->
        walk(marked, blocks, queue, did)

      not Map.has_key?(blocks, cid) ->
        Logger.warning("block sweep gave up: #{cid} is named by the tree but not stored")
        0

      true ->
        case Mst.children(blocks[cid]) do
          {:ok, children} ->
            walk(MapSet.put(marked, cid), blocks, children ++ queue, did)

          :error ->
            Logger.warning("block sweep gave up: #{cid} does not decode")
            0
        end
    end
  end

  defp walk(marked, blocks, [], did), do: sweep(marked, blocks, did)

  defp sweep(marked, blocks, did) do
    blocks
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(marked, &1))
    |> Enum.chunk_every(500)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} = Repo.delete_all(from b in Block, where: b.did == ^did and b.cid in ^chunk)
      acc + count
    end)
  end

  @doc """
  Deletes every block of `did`. The import path writes the blocks a CAR carries
  plus the nodes of the commit it signs, so it clears the table first rather
  than leaving the previous repo's blocks behind.
  """
  def delete_blocks!(did) do
    Repo.delete_all(from b in Block, where: b.did == ^did)
  end

  @doc """
  Inserts blocks; content-addressed, so conflicts are no-ops by definition.

  Batched because the rows reach SQL as one insert_all: a whole imported repo
  would otherwise bind more parameters than a statement is allowed.
  """
  def insert_blocks!(did, blocks) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    blocks
    |> Stream.map(fn {cid_string, data} ->
      %{cid: cid_string, did: did, data: data, inserted_at: now}
    end)
    |> Stream.chunk_every(@blocks_per_insert)
    |> Enum.each(fn rows ->
      Repo.insert_all(Block, rows, on_conflict: :nothing, conflict_target: [:did, :cid])
    end)
  end

  # blobs

  @doc """
  Inserts the row that makes a blob fetchable; the bytes live on disk.

  on_conflict: :nothing because the CID is the content, so a second upload of
  the same bytes is not a new fact. It is first-writer-wins on the MIME type
  on purpose: re-uploading identical bytes under a different declared
  Content-Type must not change what a reader already got back.
  """
  def put_blob!(did, cid_string, mime_type, size) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert!(
      %Blob{did: did, cid: cid_string, mime_type: mime_type, size: size, inserted_at: now},
      on_conflict: :nothing,
      conflict_target: [:did, :cid]
    )
  end

  def get_blob(did, cid_string), do: Repo.get_by(Blob, did: did, cid: cid_string)

  @doc """
  The blob CIDs `did` holds, ordered, one page at a time. sync.listBlobs reads
  this: the CID is all the endpoint answers, so selecting the row's bytes or
  MIME type would pull data nobody asked for.
  """
  def blob_cids(did, limit, offset) do
    Repo.all(
      from b in Blob,
        where: b.did == ^did,
        order_by: b.cid,
        limit: ^limit,
        offset: ^offset,
        select: b.cid
    )
  end

  # events

  # The seq sequence is a stream cursor, so its high-water mark is kept outside
  # the log: retention deletes rows, and a number the log no longer holds is
  # still a number a consumer is holding.
  @event_seq_key "event:seq"

  def max_seq do
    Repo.one(from e in Event, select: max(e.seq)) || 0
  end

  @doc """
  The next event sequence number: one past the mark.

  The mark is read and written inside the same transaction that inserts the
  event it belongs to, so two writers cannot claim the same number and a
  rollback takes the mark back with the row it was going to describe.

  A database written before the mark existed has no row here, so the log's own
  maximum is the floor rather than zero.
  """
  def claim_event_seq, do: event_seq_mark() + 1

  defp event_seq_mark do
    case get_meta(@event_seq_key) do
      nil -> max_seq()
      value -> String.to_integer(value)
    end
  end

  @doc """
  Inserts one event row with its payload already encoded, and moves the mark
  onto its seq.

  A seq the log already holds is answered with a rollback rather than raised:
  the frame would go out describing a commit under a number a consumer has
  already seen, so the caller has to treat it as a failed write rather than as
  a crash.
  """
  def insert_event!(did, seq, payload) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    case Repo.insert_all(
           Event,
           [%{seq: seq, did: did, payload: payload, inserted_at: now}],
           on_conflict: :nothing,
           conflict_target: [:seq],
           returning: [:seq]
         ) do
      {1, [event]} ->
        # Frames go out in seq order, so the last insert of a commit is the
        # highest one and the mark never moves backwards.
        put_meta!(@event_seq_key, Integer.to_string(seq))

        event.seq

      {0, _} ->
        Repo.rollback(:event_seq_taken)
    end
  end

  def events_after(cursor, limit \\ 10_000) do
    Repo.all(
      from e in Event,
        where: e.seq > ^cursor,
        order_by: e.seq,
        limit: ^limit,
        select: e.payload
    )
  end

  def oldest_seq do
    Repo.one(from e in Event, select: min(e.seq))
  end

  @doc """
  Deletes every row a DID owns in the repository layer: its records, blocks,
  blob rows and meta rows.

  Event rows are not touched. The firehose log is how a mirror learns the
  account was deleted, so a repo whose account is gone still has a `#account`
  frame with its DID on it, and the seq sequence stays gap-free.
  """
  def delete_repo_data!(did) do
    Repo.delete_all(from r in Record, where: r.did == ^did)
    Repo.delete_all(from b in Block, where: b.did == ^did)
    Repo.delete_all(from b in Blob, where: b.did == ^did)
    delete_meta!(did)
    :ok
  end

  # Meta is keyed by "<kind>:<did>", and a DID is not LIKE-safe: did:web
  # percent-encodes a non-default port, so one can carry a literal % that the
  # pattern would read as a wildcard and match another repo's rows. Selecting
  # the keys and deleting exactly those cannot.
  defp delete_meta!(did) do
    keys =
      Repo.all(from m in Meta, select: m.key) |> Enum.filter(&String.ends_with?(&1, did))

    Repo.delete_all(from m in Meta, where: m.key in ^keys)
    :ok
  end

  @doc """
  Deletes events older than `datetime`, answering how many rows went.

  The seq of the surviving rows is not renumbered, and neither is the sequence
  itself: the mark the next seq is claimed from lives in meta, so an emptied log
  still hands out numbers above every one it ever held. A consumer whose cursor
  falls inside the deleted window already gets an OutdatedCursor frame from the
  firehose replay, which is exactly what this makes possible.
  """
  def delete_events_before(datetime) do
    {count, _} = Repo.delete_all(from e in Event, where: e.inserted_at < ^datetime)
    count
  end

  # meta

  def get_meta(key) do
    case Repo.get(Meta, key) do
      nil -> nil
      %Meta{value: value} -> value
    end
  end

  def put_meta!(key, value) do
    Repo.insert!(%Meta{key: key, value: value},
      on_conflict: {:replace, [:value]},
      conflict_target: [:key]
    )
  end

  @doc """
  Writes the four head meta rows a prepared commit leaves behind: the MST root,
  the rev, the tid counter and the head commit.

  The commit path and the import path both need exactly these four, and writing
  them here keeps the two from drifting on which keys a head is made of.
  """
  def put_head!(did, prepared) do
    put_meta!("root:" <> did, CID.to_string(prepared.root_cid))
    put_meta!("rev:" <> did, prepared.rev)
    put_meta!("tid_int:" <> did, Integer.to_string(prepared.tid_int))
    put_meta!("commit:" <> did, CID.to_string(prepared.commit_cid))
  end

  @doc """
  The rev and head commit of every hosted repo, keyed by DID.

  Meta is where a repo's rev and head live, so this reads them all in one
  pass rather than one lookup per repo. A repo with no rev yet has no rows
  here at all, so the caller decides what an absent entry means.
  """
  def all_repo_heads do
    Repo.all(
      from m in Meta,
        where: like(m.key, "rev:%") or like(m.key, "commit:%"),
        select: {m.key, m.value}
    )
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case String.split(key, ":", parts: 2) do
        ["rev", did] -> Map.update(acc, did, %{rev: value}, &Map.put(&1, :rev, value))
        ["commit", did] -> Map.update(acc, did, %{head: value}, &Map.put(&1, :head, value))
        _other -> acc
      end
    end)
  end
end
