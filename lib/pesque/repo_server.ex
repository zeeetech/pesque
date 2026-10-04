defmodule Pesque.RepoServer do
  @moduledoc """
  One process per repository. Owns the in-memory entry map, the rev
  counter, the account's signing key, and every commit. Writes are serialized
  through the process, which is exactly the consistency model a PDS needs.

  The signing key is the account's, not the server's, so the process that
  owns a repo is the process that signs its commits.
  """

  use GenServer

  alias Pesque.CBOR
  alias Pesque.CID
  # API
  alias Pesque.Keys
  alias Pesque.Lexicon
  alias Pesque.Mst
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.Secp256k1
  alias Pesque.Tid

  @nsid_regex ~r/^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/
  # callbacks
  @rkey_regex ~r/^[a-zA-Z0-9._~:-]{1,512}$/

  defstruct [:did, :clock_id, :priv, entries: %{}, tid_int: 0, rev: nil]

  def start_link(did) do
    GenServer.start_link(__MODULE__, did, name: {:via, Registry, {Pesque.RepoRegistry, did}})
  end

  def create_record(pid, collection, rkey, record),
    do: GenServer.call(pid, {:write, :create, collection, rkey, record}, 15_000)

  def put_record(pid, collection, rkey, record),
    do: GenServer.call(pid, {:write, :put, collection, rkey, record}, 15_000)

  def delete_record(pid, collection, rkey),
    do: GenServer.call(pid, {:delete, collection, rkey}, 15_000)

  def entries(pid), do: GenServer.call(pid, :entries)

  @impl true
  def init(did) do
    entries =
      did
      |> RepoStore.records_for()
      |> Map.new(fn r -> {r.collection <> "/" <> r.rkey, CID.parse(r.cid)} end)

    {:ok, key} = Keys.ensure(did)

    state = %__MODULE__{
      did: did,
      clock_id: :rand.uniform(1024) - 1,
      priv: key.priv,
      entries: entries,
      tid_int: int_meta("tid_int:" <> did, 0),
      rev: RepoStore.get_meta("rev:" <> did)
    }

    {:ok, state, {:continue, :genesis_if_needed}}
  end

  @impl true
  def handle_continue(:genesis_if_needed, state) do
    if state.rev == nil do
      # Genesis commit: a signed head over the empty tree, so the repo
      # has a valid, verifiable head before the first record exists.
      {state, _result} = commit(state, [])
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:write, action, collection, rkey, record}, _from, state) do
    with :ok <- validate_collection(collection),
         {:ok, rkey, state} <- ensure_rkey(rkey, state) do
      key = collection <> "/" <> rkey

      case {action, Map.has_key?(state.entries, key)} do
        {:create, true} ->
          {:reply, {:error, :record_exists}, state}

        _ ->
          case Lexicon.from_json(record) do
            {:ok, internal} ->
              data = CBOR.encode(internal)
              cid = CID.from_data(data)

              change = %{
                action: write_action(action, state.entries, key),
                key: key,
                cid: cid,
                data: data
              }

              {state, result} = commit(state, [change])
              # commit machinery
              {:reply, {:ok, result}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, collection, rkey}, _from, state) do
    with :ok <- validate_collection(collection),
         :ok <- validate_rkey_present(rkey) do
      key = collection <> "/" <> rkey

      if Map.has_key?(state.entries, key) do
        change = %{action: "delete", key: key, cid: nil, data: nil}
        {state, result} = commit(state, [change])
        {:reply, {:ok, result}, state}
      else
        {:reply, {:error, :record_not_found}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp write_action(:create, _entries, _key), do: "create"

  defp write_action(:put, entries, key),
    do: if(Map.has_key?(entries, key), do: "update", else: "create")

  defp commit(state, changes) do
    entries2 =
      Enum.reduce(changes, state.entries, fn
        %{action: "delete", key: key}, acc -> Map.delete(acc, key)
        %{key: key, cid: cid}, acc -> Map.put(acc, key, cid)
      end)

    {root_cid, node_blocks} = Mst.build(entries2)
    {rev, tid_int} = Tid.next(state.tid_int, state.clock_id)

    unsigned = %{
      "did" => state.did,
      "version" => 3,
      "data" => root_cid,
      "rev" => rev,
      "prev" => nil
    }

    sig = Secp256k1.sign(state.priv, CBOR.encode(unsigned))
    commit_obj = Map.put(unsigned, "sig", %CBOR.Bytes{data: sig})
    commit_bytes = CBOR.encode(commit_obj)
    commit_cid = CID.from_data(commit_bytes)

    all_blocks =
      node_blocks
      |> Map.merge(Map.new(for %{cid: cid, data: data} <- changes, data != nil, do: {cid, data}))
      |> Map.put(commit_cid, commit_bytes)

    {:ok, frame} =
      Repo.transaction(fn ->
        # First statement in the transaction: the database assigns the
        # sequence number here, and the write takes SQLite's lock before
        # anything below reads. The payload lands in put_event_payload!/2,
        # because the frame that carries it needs this seq.
        seq = RepoStore.insert_event!(state.did, <<>>)

        cid_strings = Enum.map(Map.keys(all_blocks), &CID.to_string/1)
        existing = RepoStore.existing_cids(state.did, cid_strings)

        new_blocks =
          for {cid, bytes} <- all_blocks,
              not MapSet.member?(existing, CID.to_string(cid)),
              into: %{},
              do: {CID.to_string(cid), bytes}

        RepoStore.insert_blocks!(state.did, new_blocks)

        Enum.each(changes, fn
          %{action: "delete", key: key} ->
            [collection, rkey] = String.split(key, "/", parts: 2)
            RepoStore.delete_record!(state.did, collection, rkey)

          %{key: key, cid: cid, data: data} ->
            [collection, rkey] = String.split(key, "/", parts: 2)
            RepoStore.put_record!(state.did, collection, rkey, CID.to_string(cid), data)
        end)

        RepoStore.put_meta!("root:" <> state.did, CID.to_string(root_cid))
        RepoStore.put_meta!("rev:" <> state.did, rev)
        RepoStore.put_meta!("tid_int:" <> state.did, Integer.to_string(tid_int))
        RepoStore.put_meta!("commit:" <> state.did, CID.to_string(commit_cid))

        frame = build_frame(state, seq, commit_cid, rev, new_blocks, changes)
        RepoStore.put_event_payload!(seq, frame)
        frame
      end)

    Registry.dispatch(Pesque.EventRegistry, :firehose, fn listeners ->
      for {pid, _} <- listeners, do: send(pid, {:firehose_frame, frame})
    end)

    new_state = %{state | entries: entries2, tid_int: tid_int, rev: rev}

    result = %{
      "commit" => %{"cid" => CID.to_string(commit_cid), "rev" => rev},
      "changes" =>
        Enum.map(changes, fn c ->
          %{
            "uri" => "at://" <> state.did <> "/" <> c.key,
            "cid" => if(c.cid, do: CID.to_string(c.cid)),
            "action" => c.action
          }
        end)
    }

    {new_state, result}
  end

  defp build_frame(state, seq, commit_cid, rev, new_blocks, changes) do
    car =
      Pesque.Car.encode(
        [commit_cid],
        Map.new(new_blocks, fn {cid_string, bytes} -> {CID.parse(cid_string), bytes} end)
      )

    ops =
      Enum.map(changes, fn c ->
        %{"action" => c.action, "path" => c.key, "cid" => c.cid}
      end)

    header = CBOR.encode(%{"op" => 1, "t" => "#commit"})

    body =
      CBOR.encode(%{
        "seq" => seq,
        "rebase" => false,
        "tooBig" => false,
        "repo" => state.did,
        "commit" => commit_cid,
        "rev" => rev,
        "since" => state.rev,
        "blocks" => %CBOR.Bytes{data: car},
        "ops" => ops,
        "blobs" => [],
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    header <> body
  end

  # validation

  defp validate_collection(collection) when is_binary(collection) do
    if Regex.match?(@nsid_regex, collection) do
      :ok
    else
      {:error, :invalid_collection}
    end
  end

  defp validate_collection(_), do: {:error, :invalid_collection}

  # An omitted rkey gets a fresh TID from the same counter that drives
  # commit revs, so a generated key can never collide with any rev or
  # rkey this process has issued before.
  defp ensure_rkey(nil, state) do
    {tid, tid_int} = Tid.next(state.tid_int, state.clock_id)
    {:ok, tid, %{state | tid_int: tid_int}}
  end

  defp ensure_rkey(rkey, state) when is_binary(rkey) do
    case validate_rkey_present(rkey) do
      :ok -> {:ok, rkey, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_rkey(_rkey, _state), do: {:error, :invalid_rkey}

  defp validate_rkey_present(rkey) when is_binary(rkey) do
    cond do
      rkey in [".", ".."] -> {:error, :invalid_rkey}
      Regex.match?(@rkey_regex, rkey) -> :ok
      true -> {:error, :invalid_rkey}
    end
  end

  defp validate_rkey_present(_), do: {:error, :invalid_rkey}

  defp int_meta(key, default) do
    case RepoStore.get_meta(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
