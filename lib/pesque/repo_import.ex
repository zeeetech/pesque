defmodule Pesque.RepoImport do
  @moduledoc """
  The write half of importRepo: a decoded CAR becomes this server's repo.

  The HTTP controller decodes and validates the CAR and hands the result here,
  because replacing a repo is a domain operation rather than a request one: it
  signs a commit, stops the process that caches the repo, and replaces every
  row in one transaction.
  """

  alias Pesque.Accounts.User
  alias Pesque.CID
  alias Pesque.Commit
  alias Pesque.EventFrames
  alias Pesque.Events
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore

  @doc """
  Signs a new commit over the imported tree and replaces the stored repo with
  it.

  The commit the CAR carried cannot keep its signature: this is a did:web
  server and the key for the DID is the one this server holds, not the one the
  exporting PDS signed with. So the import signs a new commit over the imported
  tree with this server's key for the account, and that commit's `prev` is the
  imported commit's CID, which continues the chain instead of starting a second
  one.

  The new commit is built and signed before the store is touched, so a key this
  server cannot load leaves the existing repo exactly as it was. The process is
  stopped before the rows are replaced, because it caches the entries and head
  those rows hold; it starts again, from the rows this wrote, on the next
  request.
  """
  def persist_import(did, imported) do
    case Keys.ensure(did) do
      {:ok, key} ->
        state = %{
          did: did,
          clock_id: :rand.uniform(1024) - 1,
          priv: key.priv,
          entries: imported.entries,
          rev: nil,
          tid_int: 0,
          commit_cid: imported.commit_cid,
          root_cid: nil
        }

        {:ok, prepared} = Commit.commit(state, [])
        RepoServer.stop(did)
        write_import(did, imported, prepared)

      {:error, _reason} ->
        {:error, :key_unavailable}
    end
  end

  defp write_import(did, imported, prepared) do
    new_blocks =
      Map.new(prepared.all_blocks, fn {cid, bytes} -> {CID.to_string(cid), bytes} end)

    result =
      Repo.transaction(
        fn ->
          active? = match?(%User{active: true}, Repo.get_by(User, did: did))

          RepoStore.delete_records!(did)
          RepoStore.delete_blocks!(did)
          RepoStore.insert_blocks!(did, Map.merge(imported.blocks, new_blocks))

          Enum.each(imported.records, fn {key, {cid, data}} ->
            [collection, rkey] = String.split(key, "/", parts: 2)
            RepoStore.put_record!(did, collection, rkey, CID.to_string(cid), data)
          end)

          RepoStore.put_head!(did, prepared)

          if active? do
            seq = RepoStore.claim_event_seq()
            commit_bytes = Map.fetch!(prepared.all_blocks, prepared.commit_cid)

            case EventFrames.sync(seq, did, prepared.rev, prepared.commit_cid, commit_bytes) do
              {:ok, frame} ->
                RepoStore.insert_event!(did, seq, frame)
                frame

              {:error, reason} ->
                Repo.rollback(reason)
            end
          else
            nil
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, frame} when is_binary(frame) ->
        _ = Events.broadcast(frame)
        {:ok, did}

      {:ok, nil} ->
        {:ok, did}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
