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

  # Genesis retry pacing. A commit that rolls back because the database was
  # busy at boot clears in milliseconds, so the first retry is short: the
  # account is headless for a fifth of a second rather than forever. Doubling
  # from there reaches the ceiling in eight attempts, about fifty seconds, and
  # from then on a database that is refusing writes outright is probed once
  # every thirty seconds. The numbers are here rather than in a config file
  # because a genesis that keeps failing is a broken database, not a
  # deployment knob, and the process has to keep serving an already-genesied
  # repo while it waits.
  @genesis_retry_initial 200
  @genesis_retry_factor 2
  @genesis_retry_ceiling 30_000

  defstruct [
    :did,
    :clock_id,
    :priv,
    :commit_cid,
    :root_cid,
    :fetch,
    entries: %{},
    tid_int: 0,
    rev: nil,
    genesis_delay: nil
  ]

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
             root_cid: cid_meta("root:" <> did),
             fetch: RepoStore.block_fetcher(did),
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
  def handle_continue(:genesis_if_needed, state), do: {:noreply, genesis(state)}

  @impl true
  def handle_info(:genesis_retry, state), do: {:noreply, genesis(state)}

  # Genesis commit: a signed head over the empty tree, so the repo has a
  # valid, verifiable head before the first record exists.
  #
  # A repo that already has a head is left alone, which is also what makes a
  # retry that fires after the head exists harmless: the guard answers before
  # commit/2 is ever called.
  #
  # A database that is permanently refusing writes is retried forever, at the
  # capped interval, rather than stopping this process. RepoSupervisor is a
  # DynamicSupervisor on one_for_one at its defaults, intensity 3 in 5 seconds:
  # a child that stops three times inside that window takes the supervisor
  # down, and with it every other repo on the server. One repo whose database
  # is refusing writes is a much smaller blast radius than all of them, so a
  # bounded attempt count ending in {:stop, reason} is the worse of the two
  # here, and silence is not an option at all. The repo stays a live process
  # throughout, so it keeps answering reads and keeps accepting writes while
  # genesis waits; a write would produce a head anyway, and the retry would
  # then be a no-op.
  defp genesis(%{rev: rev} = state) when not is_nil(rev), do: state

  defp genesis(state) do
    {state, result} = commit(state, [])

    case result do
      {:ok, _prepared} ->
        %{state | genesis_delay: nil}

      {:error, reason} ->
        # The transaction rolled back whole, so nothing of the commit landed
        # and the state is the one commit/2 handed back. What is left is a repo
        # with no head, which is a broken account rather than an empty one:
        # getLatestCommit and describeRepo read the head from meta and find
        # nothing, and nothing else would ever retry it. So the failure is
        # logged with the DID it belongs to, and retried.
        delay = next_genesis_delay(state.genesis_delay)

        Logger.error("genesis commit rolled back, retrying",
          did: state.did,
          reason: inspect(reason),
          retry_in_ms: delay
        )

        Process.send_after(self(), :genesis_retry, delay)
        %{state | genesis_delay: delay}
    end
  end

  defp next_genesis_delay(nil), do: @genesis_retry_initial

  defp next_genesis_delay(delay),
    do: min(delay * @genesis_retry_factor, @genesis_retry_ceiling)

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
        change = %{
          action: "delete",
          key: key,
          cid: nil,
          data: nil,
          prev_cid: Map.fetch!(state.entries, key)
        }

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
        change = %{
          action: "delete",
          key: key,
          cid: nil,
          data: nil,
          prev_cid: Map.fetch!(state.entries, key)
        }

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

             # Read only to size the frame. It is sound here only because the
             # transaction took the write lock at BEGIN: nothing can commit
             # between this read and the insert below. If that ever goes back
             # to deferred, this read stops being a consistent snapshot.
             already = RepoStore.existing_cids(state.did, Map.keys(blocks))

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
             # The frame carries only what this commit added. A frame over the
             # whole closure would report tooBig on every commit for a repo
             # past the 2MB blocks limit, and emit a #sync after each one.
             incremental = Map.drop(blocks, MapSet.to_list(already))
             frames = Commit.frames(prepared, seq, incremental, changes)

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
    log_mst(state.did, prepared.mst)

    %{
      state
      | entries: prepared.entries,
        tid_int: prepared.tid_int,
        rev: prepared.rev,
        commit_cid: prepared.commit_cid,
        root_cid: prepared.root_cid
    }
  end

  defp log_mst(_did, :incremental), do: :ok
  defp log_mst(_did, :genesis), do: :ok

  defp log_mst(did, :rebuild) do
    Logger.warning("rebuilt the MST from records", did: did, reason: :no_root)
  end

  defp log_mst(did, {:rebuild, reason}) do
    Logger.warning("rebuilt the MST from records", did: did, reason: inspect(reason))
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
