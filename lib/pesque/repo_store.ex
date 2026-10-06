defmodule Pesque.RepoStore do
  @moduledoc "All SQL for the repository layer lives here."

  import Ecto.Query

  require Logger

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Repo
  alias Pesque.RepoStore.Blob
  alias Pesque.RepoStore.Block
  alias Pesque.RepoStore.Event
  alias Pesque.RepoStore.Meta
  alias Pesque.RepoStore.Record

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

  # blocks

  def blocks_for(did) do
    Repo.all(from b in Block, where: b.did == ^did)
  end

  # A count, not a length. blocks_for/1 selects the block bytes, and a status
  # endpoint that answered from it would pull a whole repo into memory to
  # report how big it is.
  def block_count(did) do
    Repo.one(from b in Block, where: b.did == ^did, select: count(b.cid)) || 0
  end

  def existing_cids(did, cid_strings) do
    cid_strings
    # The chunk size is SQLite's bound-variable ceiling, not a tuning knob.
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from b in Block, where: b.did == ^did and b.cid in ^chunk, select: b.cid)
    end)
    |> MapSet.new()
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
    blocks = Map.new(blocks_for(did), &{&1.cid, &1.data})

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
        case children(blocks[cid]) do
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

  # An MST node carries the subtree to its left plus, per entry, the subtree
  # and the record the entry points at. A record block carries $type and none
  # of those keys, and the walk stops there rather than mistaking every record
  # for a tree.
  defp children(data) do
    case safe_decode(data) do
      {:ok, %{"l" => left, "e" => entries} = node} ->
        if Map.has_key?(node, "$type") do
          {:ok, []}
        else
          {:ok,
           Enum.reduce(entries, cid_link([], left), fn
             %{"t" => subtree, "v" => value}, acc -> acc |> cid_link(subtree) |> cid_link(value)
             _entry, acc -> acc
           end)}
        end

      {:ok, _record_or_commit} ->
        {:ok, []}

      :error ->
        :error
    end
  end

  defp safe_decode(data) do
    {:ok, CBOR.decode!(data)}
  rescue
    _ -> :error
  end

  defp cid_link(acc, nil), do: acc
  defp cid_link(acc, %CID{} = cid), do: [CID.to_string(cid) | acc]
  defp cid_link(acc, _other), do: acc

  @doc "Inserts blocks; content-addressed, so conflicts are no-ops by definition."
  def insert_blocks!(did, blocks) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      Enum.map(blocks, fn {cid_string, data} ->
        %{cid: cid_string, did: did, data: data, inserted_at: now}
      end)

    Repo.insert_all(Block, rows, on_conflict: :nothing, conflict_target: [:did, :cid])
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

  # events

  def max_seq do
    Repo.one(from e in Event, select: max(e.seq)) || 0
  end

  @doc "The next event sequence number: one past the current maximum."
  def claim_event_seq, do: max_seq() + 1

  @doc "Inserts one event row with its payload already encoded."
  def insert_event!(did, seq, payload) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {1, [event]} =
      Repo.insert_all(
        Event,
        [%{seq: seq, did: did, payload: payload, inserted_at: now}],
        returning: [:seq]
      )

    event.seq
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
  Deletes events older than `datetime`, answering how many rows went.

  The seq is not renumbered: a consumer whose cursor falls inside the deleted
  window already gets an OutdatedCursor frame from the firehose replay, which
  is exactly what this makes possible.
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
