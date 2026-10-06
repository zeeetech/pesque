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

  @doc """
  Every block of `did`, keyed by CID string.

  What the CAR endpoints and the sweep both need from the table, so the
  keying is written once.
  """
  def blocks_map(did) do
    Map.new(blocks_for(did), &{&1.cid, &1.data})
  end

  @doc """
  The stored blocks `cid_strings` names, keyed by CID string.

  A CID this repo does not hold is absent from the map rather than nil: a
  block either exists or it does not, and the caller is the one that decides
  what a missing one means. Chunked because 500 is SQLite's bound-variable
  ceiling, not a tuning knob.
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
      root -> walk_to(blocks_map(did), root, cid_string, [])
    end
  end

  # acc is reversed: a node is prepended as the walk goes down and the list is
  # reversed once at the top, which keeps the root first in what is answered.
  defp walk_to(blocks, node, target, acc) do
    case Map.fetch(blocks, node) do
      {:ok, data} ->
        case children(data) do
          {:ok, children} ->
            acc = [{node, data} | acc]

            cond do
              node == target ->
                {:ok, Enum.reverse(acc)}

              target in children ->
                case Map.fetch(blocks, target) do
                  {:ok, data} -> {:ok, Enum.reverse([{target, data} | acc])}
                  :error -> {:error, :corrupt}
                end

              true ->
                descend(blocks, children, target, acc)
            end

          :error ->
            Logger.warning("block path gave up: #{node} does not decode")
            {:error, :corrupt}
        end

      :error ->
        Logger.warning("block path gave up: #{node} is named by the tree but not stored")
        {:error, :corrupt}
    end
  end

  # Every child is tried, not just the subtree ones: the walk does not know
  # which subtree holds the target, and a child that is itself a record block
  # simply answers :not_found on the way back out.
  defp descend(_blocks, [], _target, _acc), do: {:error, :not_found}

  defp descend(blocks, [child | rest], target, acc) do
    case walk_to(blocks, child, target, acc) do
      {:ok, path} -> {:ok, path}
      {:error, :corrupt} = error -> error
      {:error, :not_found} -> descend(blocks, rest, target, acc)
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
