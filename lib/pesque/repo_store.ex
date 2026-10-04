defmodule Pesque.RepoStore do
  @moduledoc "All SQL for the repository layer lives here."

  import Ecto.Query

  alias Pesque.Repo
  alias Pesque.RepoStore.{Block, Blob, Event, Meta, Record}

  # records

  def records_for(did) do
    Repo.all(from r in Record, where: r.did == ^did)
  end

  def get_record(did, collection, rkey) do
    Repo.get_by(Record, did: did, collection: collection, rkey: rkey)
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

  def existing_cids(did, cid_strings) do
    cid_strings
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from b in Block, where: b.did == ^did and b.cid in ^chunk, select: b.cid)
    end)
    |> MapSet.new()
  end

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

  @doc "Claims the next event sequence number, assigning it in the database."
  def insert_event!(did, payload) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {1, [event]} =
      Repo.insert_all(
        Event,
        [%{seq: nil, did: did, payload: payload, inserted_at: now}],
        returning: [:seq]
      )

    event.seq
  end

  def put_event_payload!(seq, payload) do
    query = from e in Event, where: e.seq == ^seq, update: [set: [payload: ^payload]]
    {1, _} = Repo.update_all(query, [])

    :ok
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
end
