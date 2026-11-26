defmodule Pesque.RepoServer do
  @moduledoc """
  One process per repository. Owns the rev counter, the account's signing key,
  and every commit. Writes are serialized through the process, which is exactly
  the consistency model a PDS needs.

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
  # busy at boot clears in milliseconds, so the retry is short: the account is
  # headless for a fifth of a second rather than forever. The number is here
  # rather than in a config file because a genesis that keeps failing is a
  # broken database, not a deployment knob, and the process has to keep serving
  # an already-genesied repo while it waits.
  @genesis_retry_interval 200

  defstruct [
    :did,
    :clock_id,
    :priv,
    :commit_cid,
    :root_cid,
    :fetch,
    tid_int: 0,
    rev: nil
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
    rev and tid counter those rows hold, so a write landing after the deletes
    would put the repo back and leave the account deleted but still writable
    from a process nothing holds a token for.
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
    case Keys.ensure(did) do
      {:ok, key} ->
        {:ok,
         %__MODULE__{
           did: did,
           clock_id: :rand.uniform(1024) - 1,
           priv: key.priv,
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
  # fixed interval, rather than stopping this process. RepoSupervisor is a
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
    {next_state, result} = commit(state, [])

    case result do
      {:ok, _prepared} ->
        next_state

      {:error, reason} ->
        # With no head, getLatestCommit and describeRepo have nothing to read,
        # and no other path would retry genesis.
        Logger.error("genesis commit rolled back, retrying",
          did: state.did,
          reason: inspect(reason),
          retry_in_ms: @genesis_retry_interval
        )

        Process.send_after(self(), :genesis_retry, @genesis_retry_interval)
        state
    end
  end

  @impl true
  def handle_call(:entries, _from, state) do
    reply =
      case load_entries(state.did) do
        {:ok, entries} -> entries
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  # The single write is the batch of one: same validation, same encoding, same
  # commit, so createRecord and a batch create cannot drift apart. The op type
  # is chosen here rather than inferred from the key, because putRecord is an
  # upsert while a batch update is strict, and the two disagree on a key that is
  # not there.
  def handle_call({:write, action, collection, rkey, record, opts}, _from, state) do
    case prepare_single(action, collection, rkey, record, opts, state) do
      {:ok, next_state, changes} ->
        reply_commit(state, next_state, changes)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, collection, rkey}, _from, state) do
    with :ok <- validate_collection(collection),
         :ok <- validate_rkey_present(rkey),
         {:ok, prev_cid} <- RepoStore.record_cid(state.did, collection, rkey) do
      if prev_cid do
        key = collection <> "/" <> rkey

        change = %{
          action: "delete",
          key: key,
          cid: nil,
          data: nil,
          prev_cid: prev_cid
        }

        reply_commit(state, state, [change])
      else
        {:reply, {:error, :record_not_found}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # A batch is one commit or none. The writes are prepared against a running
  # key/CID overlay rather than the live rows, so a create and a later write to
  # the same key inside one batch see each other the way the lexicon says they
  # should, and the state is only replaced once every write has been checked.
  #
  # swapCommit is checked here, inside the same serialization the commit goes
  # through, because comparing it outside the process would compare against a
  # head that another write could move before this one committed.
  def handle_call({:apply_writes, writes, opts}, _from, state) do
    with :ok <- check_swap(state, Keyword.get(opts, :swap_commit)),
         {:ok, next_state, changes} <- prepare(writes, state, opts) do
      reply_commit(state, next_state, changes)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp prepare_single(:create, collection, rkey, record, opts, state) do
    write = %{
      "$type" => "com.atproto.repo.applyWrites#create",
      "collection" => collection,
      "rkey" => rkey,
      "value" => record
    }

    unwrap_single(prepare([write], state, opts))
  end

  defp prepare_single(:put, collection, rkey, record, opts, state) do
    with :ok <- validate_collection(collection),
         {:ok, rkey, state} <- ensure_rkey(rkey, state),
         {:ok, prev_cid} <- RepoStore.record_cid(state.did, collection, rkey) do
      type =
        if prev_cid,
          do: "com.atproto.repo.applyWrites#update",
          else: "com.atproto.repo.applyWrites#create"

      write = %{"$type" => type, "collection" => collection, "rkey" => rkey, "value" => record}
      unwrap_single(prepare([write], state, opts))
    end
  end

  # A single write's failure is the write's own, not a batch index's: the batch
  # wraps it as write 1, and the caller of the single path never saw an index.
  defp unwrap_single({:ok, next_state, changes}), do: {:ok, next_state, changes}
  defp unwrap_single({:error, {:write_failed, 1, reason}}), do: {:error, reason}
  defp unwrap_single({:error, reason}), do: {:error, reason}

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
    if length(writes) > Commit.max_ops() do
      {:error, :too_many_ops}
    else
      opts = [validate: Keyword.get(opts, :validate, true)]

      with {:ok, overlay} <- preload_overlay(writes, state.did) do
        writes
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, [], state, overlay}, fn
          {write, index}, {:ok, acc, state, overlay} ->
            case prepare_write(write, state, overlay, opts) do
              {:ok, change, state, overlay} ->
                {:cont, {:ok, [change | acc], state, overlay}}

              {:error, reason} ->
                {:halt, {:error, {:write_failed, index, reason}}}
            end
        end)
        |> case do
          {:ok, acc, state, _overlay} -> {:ok, state, Enum.reverse(acc)}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp prepare(_writes, _state, _opts), do: {:error, :invalid_writes}

  defp preload_overlay(writes, did) do
    pairs = explicit_record_keys(writes)

    with {:ok, overlay} <- RepoStore.record_cids(did, pairs) do
      overlay =
        Enum.reduce(pairs, overlay, fn {collection, rkey}, acc ->
          Map.put_new(acc, collection <> "/" <> rkey, nil)
        end)

      {:ok, overlay}
    end
  end

  defp explicit_record_keys(writes) do
    writes
    |> Enum.reduce([], fn
      %{"collection" => collection, "rkey" => rkey}, acc
      when is_binary(collection) and is_binary(rkey) ->
        [{collection, rkey} | acc]

      _write, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  # rkey generation draws on the same TID counter createRecord does, so a
  # create without one here cannot collide with a key or rev this process has
  # already issued.
  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#create"} = write,
         state,
         overlay,
         opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         {:ok, record} <- Record.check(write["collection"], write["value"], opts),
         {:ok, rkey, state} <- ensure_rkey(write["rkey"], state) do
      key = write["collection"] <> "/" <> rkey

      with {:ok, overlay} <- ensure_overlay_key(key, overlay, state.did) do
        if overlay[key] do
          {:error, :record_exists}
        else
          encode(:create, key, record, state, overlay)
        end
      end
    end
  end

  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#update"} = write,
         state,
         overlay,
         opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         :ok <- validate_rkey_present(write["rkey"]),
         {:ok, record} <- Record.check(write["collection"], write["value"], opts) do
      key = write["collection"] <> "/" <> write["rkey"]

      with {:ok, overlay} <- ensure_overlay_key(key, overlay, state.did) do
        if overlay[key] do
          encode(:put, key, record, state, overlay)
        else
          {:error, :record_not_found}
        end
      end
    end
  end

  defp prepare_write(
         %{"$type" => "com.atproto.repo.applyWrites#delete"} = write,
         state,
         overlay,
         _opts
       ) do
    with :ok <- validate_collection(write["collection"]),
         :ok <- validate_rkey_present(write["rkey"]) do
      key = write["collection"] <> "/" <> write["rkey"]

      with {:ok, overlay} <- ensure_overlay_key(key, overlay, state.did) do
        case Map.fetch!(overlay, key) do
          nil ->
            {:error, :record_not_found}

          prev_cid ->
            change = %{
              action: "delete",
              key: key,
              cid: nil,
              data: nil,
              prev_cid: prev_cid
            }

            {:ok, change, state, Map.put(overlay, key, nil)}
        end
      end
    end
  end

  defp prepare_write(%{"$type" => type}, _state, _overlay, _opts),
    do: {:error, {:unsupported_write, type}}

  defp prepare_write(_write, _state, _overlay, _opts), do: {:error, :invalid_write}

  defp encode(action, key, record, state, overlay) do
    case Commit.encode_write(overlay, action, key, record) do
      {:ok, change} ->
        {:ok, change, state, Map.put(overlay, key, change.cid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_overlay_key(key, overlay, did) do
    case Map.fetch(overlay, key) do
      {:ok, _cid_or_tombstone} ->
        {:ok, overlay}

      :error ->
        [collection, rkey] = String.split(key, "/", parts: 2)

        with {:ok, cid} <- RepoStore.record_cid(did, collection, rkey) do
          {:ok, Map.put(overlay, key, cid)}
        end
    end
  end

  defp reply_commit(state, next_state, changes) do
    {committed_state, result} = commit(next_state, changes)

    case result do
      {:ok, _} -> {:reply, result, committed_state}
      {:error, _} -> {:reply, result, state}
    end
  end

  defp commit(state, changes) do
    case Commit.commit(state, changes, fn -> load_entries(state.did) end) do
      {:ok, prepared} ->
        commit_prepared(state, changes, prepared)

      {:error, reason} ->
        {state, {:error, reason}}
    end
  end

  defp commit_prepared(state, changes, prepared) do
    # immediate, because the first statement in here reads the seq mark and a
    # deferred transaction that read before another connection committed cannot
    # upgrade its snapshot to a write: SQLite answers SQLITE_BUSY_SNAPSHOT at
    # once, and a busy timeout does not make a stale snapshot current. Two
    # accounts committing at the same time is enough to hit it.
    case Repo.transaction(
           fn ->
             seq = RepoStore.claim_event_seq()

             case Commit.frame(prepared, seq, changes) do
               {:ok, {^seq, frame}} ->
                 blocks =
                   Map.new(prepared.all_blocks, fn {cid, bytes} ->
                     {CID.to_string(cid), bytes}
                   end)

                 # Inserts are idempotent so a sweep between identical commits
                 # cannot collect a block named by the new head.
                 RepoStore.insert_blocks!(state.did, blocks)

                 Enum.each(changes, fn
                   %{action: "delete", key: key} ->
                     [collection, rkey] = String.split(key, "/", parts: 2)
                     RepoStore.delete_record!(state.did, collection, rkey)

                   %{key: key, cid: cid, data: data} ->
                     [collection, rkey] = String.split(key, "/", parts: 2)
                     RepoStore.put_record!(state.did, collection, rkey, CID.to_string(cid), data)
                 end)

                 RepoStore.put_head!(state.did, prepared)
                 RepoStore.insert_event!(state.did, seq, frame)
                 frame

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           end,
           mode: :immediate
         ) do
      {:ok, frame} ->
        Pesque.Events.broadcast(frame)
        {next_state(state, prepared), {:ok, prepared.result}}

      {:error, :event_seq_taken} ->
        {state, {:error, :busy}}

      {:error, reason} ->
        {state, {:error, reason}}
    end
  end

  defp next_state(state, prepared) do
    log_mst(state.did, prepared.mst)

    %{
      state
      | tid_int: prepared.tid_int,
        rev: prepared.rev,
        commit_cid: prepared.commit_cid,
        root_cid: prepared.root_cid
    }
  end

  defp log_mst(_did, :incremental), do: :ok
  defp log_mst(_did, :genesis), do: :ok

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
