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

  defstruct [:did, :clock_id, :priv, entries: %{}, tid_int: 0, rev: nil]

  def start_link(did) do
    GenServer.start_link(__MODULE__, did, name: {:via, Registry, {Pesque.RepoRegistry, did}})
  end

  def create_record(pid, collection, rkey, record, opts \\ []),
    do: GenServer.call(pid, {:write, :create, collection, rkey, record, opts}, 15_000)

  def put_record(pid, collection, rkey, record, opts \\ []),
    do: GenServer.call(pid, {:write, :put, collection, rkey, record, opts}, 15_000)

  def delete_record(pid, collection, rkey),
    do: GenServer.call(pid, {:delete, collection, rkey}, 15_000)

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
    entries =
      did
      |> RepoStore.records_for()
      |> Map.new(fn r -> {r.collection <> "/" <> r.rkey, CID.parse(r.cid)} end)

    case Keys.ensure(did) do
      {:ok, key} ->
        {:ok,
         %__MODULE__{
           did: did,
           clock_id: :rand.uniform(1024) - 1,
           priv: key.priv,
           entries: entries,
           tid_int: int_meta("tid_int:" <> did, 0),
           rev: RepoStore.get_meta("rev:" <> did)
         }, {:continue, :genesis_if_needed}}

      {:error, reason} ->
        Logger.error("repo for #{did} cannot sign: #{inspect(reason)}")
        {:stop, {:key_unavailable, reason}}
    end
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
        {:reply, {:ok, result}, state}
      else
        {:reply, {:error, :record_not_found}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Split out of the write clause so the record check is the last thing that
  # clause reads as before the encoding starts.
  defp encode_write(state, action, key, record) do
    case Commit.encode_write(state.entries, action, key, record) do
      {:ok, change} ->
        {state, result} = commit(state, [change])
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp commit(state, changes) do
    {:ok, prepared} = Commit.commit(state, changes)

    {:ok, frame} =
      Repo.transaction(fn ->
        # The seq comes first because the frame carries it; the event row
        # is inserted with its payload already encoded, so a crash can
        # never leave an empty-payload row behind. Two writers racing on
        # the same seq lose on the primary key and roll back whole.
        seq = RepoStore.claim_event_seq()

        cid_strings = Enum.map(Map.keys(prepared.all_blocks), &CID.to_string/1)
        existing = RepoStore.existing_cids(state.did, cid_strings)

        new_blocks =
          for {cid, bytes} <- prepared.all_blocks,
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

        RepoStore.put_meta!("root:" <> state.did, CID.to_string(prepared.root_cid))
        RepoStore.put_meta!("rev:" <> state.did, prepared.rev)
        RepoStore.put_meta!("tid_int:" <> state.did, Integer.to_string(prepared.tid_int))
        RepoStore.put_meta!("commit:" <> state.did, CID.to_string(prepared.commit_cid))

        frame = Commit.frame(prepared, seq, new_blocks, changes)
        RepoStore.insert_event!(state.did, seq, frame)
        frame
      end)

    Registry.dispatch(Pesque.EventRegistry, :firehose, fn listeners ->
      for {pid, _} <- listeners, do: send(pid, {:firehose_frame, frame})
    end)

    {%{state | entries: prepared.entries, tid_int: prepared.tid_int, rev: prepared.rev},
     prepared.result}
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
