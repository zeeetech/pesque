defmodule Pesque.RepoServer do
  @moduledoc """
  One process per repository. Owns the in-memory entry map, the rev
  counter, the account's signing key, and every commit. Writes are serialized
  through the process, which is exactly the consistency model a PDS needs.

  The signing key is the account's, not the server's, so the process that
  owns a repo is the process that signs its commits.
  """

  use GenServer

  require Logger

  alias Pesque.CID
  alias Pesque.Commit
  alias Pesque.Keys
  alias Pesque.Record
  alias Pesque.Repo
  alias Pesque.RepoStore
  alias Pesque.Tid

  @nsid_regex ~r/^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/
  @rkey_regex ~r/^[a-zA-Z0-9._~:-]{1,512}$/

  defstruct [:did, :clock_id, :priv, :commit_cid, entries: %{}, tid_int: 0, rev: nil]

  def start_link(did) do
    GenServer.start_link(__MODULE__, did, name: {:via, Registry, {Pesque.RepoRegistry, did}})
  end

  def create_record(pid, collection, rkey, record, opts \\ []),
    do: GenServer.call(pid, {:write, :create, collection, rkey, record, opts}, 15_000)

  def put_record(pid, collection, rkey, record, opts \\ []),
    do: GenServer.call(pid, {:write, :put, collection, rkey, record, opts}, 15_000)

  def delete_record(pid, collection, rkey),
    do: GenServer.call(pid, {:delete, collection, rkey}, 15_000)

  @doc """
  Applies a batch of writes as one commit, or none of them.

  `writes` is the lexicon shape: a list of maps carrying `$type` of
  applyWrites#create, #update or #delete. Every write is checked before any of
  them is committed, so a bad one names its own index in the error and leaves
  the repo exactly as it was.
  """
  def apply_writes(pid, writes, opts \\ []),
    do: GenServer.call(pid, {:apply_writes, writes, opts}, 30_000)

  def entries(pid), do: GenServer.call(pid, :entries)

  @doc """
  Stops the process for `did`, if one is running. Answers whether one was.

  Deleting an account calls this before its rows go: a RepoServer caches the
  entry map, rev and tid counter those rows hold, so a write landing after the
  deletes would put the repo back and leave the account deleted but still
  writable from a process nothing holds a token for.
  """
  def stop(did) do
    case Registry.lookup(Pesque.RepoRegistry, did) do
      [{pid, _value}] ->
        DynamicSupervisor.terminate_child(Pesque.RepoSupervisor, pid)
        {:ok, :stopped}

      [] ->
        :ok
    end
  end

  @impl true
  def init(did) do
    with {:ok, entries} <- load_entries(did) do
      case Keys.ensure(did) do
        {:ok, key} ->
          {:ok,
           %__MODULE__{
             did: did,
             clock_id: :rand.uniform(1024) - 1,
             priv: key.priv,
             entries: entries,
             # The head comes from meta, not from a process that may have died:
             # a commit written before a restart still has to chain from it, and
             # the commit object it writes names it in prev.
             commit_cid: cid_meta("commit:" <> did),
             tid_int: int_meta("tid_int:" <> did, 0),
             rev: RepoStore.get_meta("rev:" <> did)
           }, {:continue, :genesis_if_needed}}

        {:error, reason} ->
          Logger.error("repo for #{did} cannot sign: #{inspect(reason)}")
          {:stop, {:key_unavailable, reason}}
      end
    end
  end

  defp load_entries(did) do
    did
    |> RepoStore.records_for()
    |> Enum.reduce_while({:ok, %{}}, fn record, {:ok, acc} ->
      case CID.safe_parse(record.cid) do
        {:ok, cid} ->
          {:cont, {:ok, Map.put(acc, record.collection <> "/" <> record.rkey, cid)}}

        :error ->
          Logger.error("stored cid does not parse",
            did: did,
            key: record.collection <> "/" <> record.rkey
          )

          {:halt, {:error, {:corrupt_record, record.collection <> "/" <> record.rkey}}}
      end
    end)
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

  def handle_call({:write, action, collection, rkey, record, opts}, _from, state) do
    with :ok <- validate_collection(collection),
         {:ok, rkey, state} <- ensure_rkey(rkey, state) do
      key = collection <> "/" <> rkey

      case {action, Map.has_key?(state.entries, key)} do
        {:create, true} ->
          {:reply, {:error, :record_exists}, state}

        _ ->
          case Record.check(collection, record, opts) do
            {:ok, record} -> encode_write(state, action, key, record)
            {:error, _reason} = error -> {:reply, error, state}
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
        {:reply, result, state}
      else
        {:reply, {:error, :record_not_found}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A batch is one commit or none. The writes are prepared against a running
  # view of the entry map rather than the live one, so a create and a later
  # write to the same key inside one batch see each other the way the lexicon
  # says they should, and the state is only replaced once every write has been
  # checked.
  #
  # swapCommit is checked here, inside the same serialization the commit goes
  # through, because comparing it outside the process would compare against a
  # head that another write could move before this one committed.
  def handle_call({:apply_writes, writes, opts}, _from, state) do
    with :ok <- check_swap(state, Keyword.get(opts, :swap_commit)),
         {:ok, next_state, changes} <- prepare(writes, state, opts) do
      {state, result} = commit(next_state, changes)
      {:reply, result, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # swapCommit is compared against the stored head rather than the one this
  # process cached, so a head another writer moved while this repo was down is
  # still seen as a mismatch.
  defp check_swap(_state, nil), do: :ok

  defp check_swap(state, swap_commit) do
    head = RepoStore.get_meta("commit:" <> state.did)

    if head == swap_commit, do: :ok, else: {:error, :invalid_swap}
  end

  # Answers the state the batch would leave behind and the changes that get it
  # there. Nothing here touches the database: a batch that fails halfway leaves
  # the live state untouched because the running one was never it.
  defp prepare(writes, state, opts) when is_list(writes) do
    opts = [validate: Keyword.get(opts, :validate, true)]

    writes
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], state}, fn {write, index}, {:ok, acc, state} ->
      case prepare_write(write, state, opts) do
        {:ok, change, state} -> {:cont, {:ok, [change | acc], state}}
        {:error, reason} -> {:halt, {:error, {:write_failed, index, reason}}}
      end
    end)
    |> case do
      {:ok, acc, state} -> {:ok, state, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(_writes, _state, _opts), do: {:error, :invalid_writes}

  # rkey generation draws on the same TID counter createRecord does, so a
  # create without one here cannot collide with a key or rev this process has
  # already issued.
  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#create"} = write,
         state,
         opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         {:ok, record} <- checked(write["collection"], write["value"], opts),
         {:ok, rkey, state} <- ensure_rkey(write["rkey"], state) do
      key = write["collection"] <> "/" <> rkey

      if Map.has_key?(state.entries, key) do
        {:error, :record_exists}
      else
        encode(:create, key, record, state)
      end
    end
  end

  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#update"} = write,
         state,
         opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         :ok <- validate_rkey_present(write["rkey"]),
         {:ok, record} <- checked(write["collection"], write["value"], opts) do
      key = write["collection"] <> "/" <> write["rkey"]

      if Map.has_key?(state.entries, key) do
        encode(:put, key, record, state)
      else
        {:error, :record_not_found}
      end
    end
  end

  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#delete"} = write,
         state,
         _opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         :ok <- validate_rkey_present(write["rkey"]) do
      key = write["collection"] <> "/" <> write["rkey"]

      if Map.has_key?(state.entries, key) do
        change = %{action: "delete", key: key, cid: nil, data: nil}
        {:ok, change, %{state | entries: Map.delete(state.entries, key)}}
      else
        {:error, :record_not_found}
      end
    end
  end

  defp prepare_write(%{"$type" => type}, _state, _opts),
    do: {:error, {:unsupported_write, type}}

  defp prepare_write(_write, _state, _opts), do: {:error, :invalid_write}

  defp encode(action, key, record, state) do
    case Commit.encode_write(state.entries, action, key, record) do
      {:ok, change} ->
        {:ok, change, %{state | entries: Map.put(state.entries, key, change.cid)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checked(_collection, record, _opts) when not is_map(record),
    do: {:error, :missing_params}

  defp checked(collection, record, opts), do: Record.check(collection, record, opts)

  # Split out of the write clause so the record check is the last thing that
  # clause reads as before the encoding starts.
  defp encode_write(state, action, key, record) do
    case Commit.encode_write(state.entries, action, key, record) do
      {:ok, change} ->
        {state, result} = commit(state, [change])
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp commit(state, changes) do
    {:ok, prepared} = Commit.commit(state, changes)

    # immediate, because the first statement in here reads the seq mark and a
    # deferred transaction that read before another connection committed cannot
    # upgrade its snapshot to a write: SQLite answers SQLITE_BUSY_SNAPSHOT at
    # once, and a busy timeout does not make a stale snapshot current. Two
    # accounts committing at the same time is enough to hit it.
    case Repo.transaction(
           fn ->
             # The seq comes first because the frame carries it, and the event
             # row is inserted with its payload already encoded, so a crash can
             # never leave an empty-payload row behind. What guards the seq
             # against a second writer is insert_event!/3 rolling back on the
             # primary key, inside the transaction the claim was made in.
             seq = RepoStore.claim_event_seq()

             blocks =
               Map.new(prepared.all_blocks, fn {cid, bytes} -> {CID.to_string(cid), bytes} end)

             # Every block goes in, including the ones this repo already holds:
             # the insert is a no-op on the ones it does, and a sweep landing
             # between the two commits of an identical block would otherwise
             # collect a block the head names.
             RepoStore.insert_blocks!(state.did, blocks)

             Enum.each(changes, fn
               %{action: "delete", key: key} ->
                 [collection, rkey] = String.split(key, "/", parts: 2)
                 RepoStore.delete_record!(state.did, collection, rkey)

               %{key: key, cid: cid, data: data} ->
                 [collection, rkey] = String.split(key, "/", parts: 2)
                 RepoStore.put_record!(state.did, collection, rkey, CID.to_string(cid), data)
             end)

             RepoStore.put_meta!("root:" <> state.did, CID.to_string(prepared.root_cid))
             RepoStore.put_meta!("rev:" <> state.did, prepared.rev)
             RepoStore.put_meta!("tid_int:" <> state.did, Integer.to_string(prepared.tid_int))
             RepoStore.put_meta!("commit:" <> state.did, CID.to_string(prepared.commit_cid))

             # A commit over the lexicon's limits goes out as a #commit followed
             # by the #sync that tells a consumer to re-fetch. Both rows are
             # written here so a cursor replay hands them back in seq order.
             frames = Commit.frames(prepared, seq, blocks, changes)

             Enum.each(frames, fn {frame_seq, frame} ->
               RepoStore.insert_event!(state.did, frame_seq, frame)
             end)

             frames
           end,
           mode: :immediate
         ) do
      {:ok, frames} ->
        Enum.each(frames, fn {_frame_seq, frame} ->
          Registry.dispatch(Pesque.EventRegistry, :firehose, fn listeners ->
            for {pid, _} <- listeners, do: send(pid, {:firehose_frame, frame})
          end)
        end)

        {next_state(state, prepared), {:ok, prepared.result}}

      {:error, :event_seq_taken} ->
        # Another commit took the seq between the claim and the insert. The
        # transaction rolled back whole, so nothing of this one landed and the
        # state is untouched; the caller retries.
        {state, {:error, :busy}}
    end
  end

  defp next_state(state, prepared) do
    %{
      state
      | entries: prepared.entries,
        tid_int: prepared.tid_int,
        rev: prepared.rev,
        commit_cid: prepared.commit_cid
    }
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

  defp cid_meta(key) do
    case RepoStore.get_meta(key) do
      nil -> nil
      value -> CID.parse(value)
    end
  end
end
