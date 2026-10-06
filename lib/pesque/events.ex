defmodule Pesque.Events do
  @moduledoc """
  The firehose log outside a commit.

  A commit writes its frame inside its own transaction, because the frame
  describes the blocks that transaction just inserted. An identity or account
  event has no such coupling: it is a seq, a frame and a push, so it gets its
  own transaction here and the same log the commit path writes to, which is
  what makes cursor replay order the two together.
  """

  alias Pesque.EventFrames
  alias Pesque.Repo
  alias Pesque.RepoStore

  @doc "Announces an account's current handle."
  def emit_identity(did, handle) do
    emit(did, &EventFrames.identity(&1, did, handle))
  end

  @doc "Announces a change to whether the account has a repo here."
  def emit_account(did, status) do
    emit(did, &EventFrames.account(&1, did, status))
  end

  @doc "Pushes an already-persisted frame to every connected socket."
  def broadcast(frame) do
    Registry.dispatch(Pesque.EventRegistry, :firehose, fn listeners ->
      for {pid, _} <- listeners, do: send(pid, {:firehose_frame, frame})
    end)
  end

  defp emit(did, build) do
    {:ok, frame} =
      Repo.transaction(fn ->
        seq = RepoStore.claim_event_seq()
        frame = build.(seq)
        RepoStore.insert_event!(did, seq, frame)
        frame
      end)

    broadcast(frame)
  end
end
