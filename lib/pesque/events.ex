defmodule Pesque.Events do
  @moduledoc """
  The firehose log outside a commit. A commit writes its frame inside its own
  transaction, because the frame describes the blocks that transaction just
  inserted; an identity or account event has no such coupling, so it gets
  its own transaction here, on the same log, so cursor replay orders the
  two together.
  """

  use GenServer

  alias Pesque.Commit
  alias Pesque.CID
  alias Pesque.EventFrames
  alias Pesque.Repo
  alias Pesque.RepoStore

  # Ten maximum-size frames keep each ordered drain batch near 50 MB.
  @dispatch_batch_size 10

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{last_seq: RepoStore.event_cursor()}}

  @doc "Announces an account's current handle."
  def emit_identity(did, handle) do
    emit(did, &EventFrames.identity(&1, did, handle))
  end

  @doc "Announces a change to whether the account has a repo here."
  def emit_account(did, status) do
    emit(did, &EventFrames.account(&1, did, status))
  end

  @doc """
  Announces an active account followed by a sync of its current repo head.

  Both events share one transaction, so the sync has the immediately following
  durable sequence number. If the head cannot be synced, the account event is
  still persisted and broadcast.
  """
  def emit_account_and_sync(did) do
    result =
      Repo.transaction(
        fn ->
          account_seq = RepoStore.claim_event_seq()
          account_frame = EventFrames.account(account_seq, did, :activated)
          RepoStore.insert_event!(did, account_seq, account_frame)

          case current_head_sync(did) do
            {:ok, sync_seq, sync_frame} ->
              RepoStore.insert_event!(did, sync_seq, sync_frame)
              {:complete, account_frame, sync_frame}

            {:error, reason} ->
              {:account_only, account_frame, reason}
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, {:complete, account_frame, sync_frame}} ->
        _ = broadcast(account_frame)
        {:ok, [account_frame, sync_frame]}

      {:ok, {:account_only, account_frame, reason}} ->
        _ = broadcast(account_frame)
        {:error, {:sync_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Signals an already-persisted frame for ordered dispatch."
  def broadcast(frame) when is_binary(frame) do
    if byte_size(frame) > Commit.max_frame_bytes() do
      {:error, :frame_too_large}
    else
      target_seq = RepoStore.event_cursor()

      try do
        GenServer.call(__MODULE__, {:drain, target_seq})
      catch
        :exit, _reason -> {:error, :dispatcher_unavailable}
      end
    end
  end

  def broadcast(_frame), do: {:error, :invalid_frame}

  @impl true
  def handle_call({:drain, target_seq}, _from, state) do
    if Registry.lookup(Pesque.EventRegistry, :firehose) == [] do
      # With no listeners, the caller's durable cursor advances the watermark;
      # a later connection gets its history through its own cursor replay.
      {:reply, :ok, %{state | last_seq: max(state.last_seq, target_seq)}}
    else
      cond do
        target_seq < state.last_seq ->
          {:reply, :ok, state}

        target_seq == state.last_seq ->
          {:reply, :ok, state}

        true ->
          {:reply, :ok, drain(state, target_seq)}
      end
    end
  end

  defp emit(did, build) do
    # immediate: the first statement reads the seq mark, and a deferred
    # transaction that read before another connection committed cannot
    # upgrade its snapshot to a write (SQLite answers SQLITE_BUSY_SNAPSHOT
    # at once; a busy timeout does not make a stale snapshot current).
    case Repo.transaction(
           fn ->
             seq = RepoStore.claim_event_seq()
             frame = build.(seq)
             RepoStore.insert_event!(did, seq, frame)
             frame
           end,
           mode: :immediate
         ) do
      {:ok, frame} ->
        _ = broadcast(frame)
        {:ok, frame}

      {:error, reason} ->
        # Nothing was persisted, so there is nothing to push: a frame a
        # consumer sees and a replay does not is worse than no frame.
        {:error, reason}
    end
  end

  defp current_head_sync(did) do
    with head when is_binary(head) <- RepoStore.get_meta("commit:" <> did),
         rev when is_binary(rev) <- RepoStore.repo_rev(did),
         {:ok, commit_cid} <- CID.safe_parse(head),
         %{data: commit_bytes} when is_binary(commit_bytes) <- RepoStore.get_block(did, head),
         seq <- RepoStore.claim_event_seq(),
         {:ok, frame} <- EventFrames.sync(seq, did, rev, commit_cid, commit_bytes) do
      {:ok, seq, frame}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :repo_head_unavailable}
    end
  end

  defp drain(state, target_seq) do
    rows = RepoStore.event_rows_between(state.last_seq, target_seq, @dispatch_batch_size)

    Enum.each(rows, fn {_seq, frame} ->
      if is_binary(frame) and byte_size(frame) <= Commit.max_frame_bytes() do
        dispatch(frame)
      end
    end)

    case rows do
      [] ->
        %{state | last_seq: target_seq}

      rows ->
        {seq, _frame} = List.last(rows)
        last_seq = if length(rows) < @dispatch_batch_size, do: target_seq, else: seq
        next_state = %{state | last_seq: last_seq}

        if length(rows) == @dispatch_batch_size and seq < target_seq do
          drain(next_state, target_seq)
        else
          next_state
        end
    end
  end

  defp dispatch(frame) do
    Registry.dispatch(Pesque.EventRegistry, :firehose, fn listeners ->
      for {pid, _} <- listeners, do: send(pid, {:firehose_frame, frame})
    end)
  end
end
