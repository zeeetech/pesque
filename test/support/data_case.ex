defmodule Pesque.DataCase do
  @moduledoc """
  Per-test database isolation.

  The Repo and every RepoServer belong to the application supervision tree,
  not to the test process, so the connection cannot be owned by the test
  alone. The pool runs in shared mode instead: every process's queries are
  routed to the connection the test checked out, which is what lets a
  RepoServer started mid-test write inside the test's transaction and be
  rolled back with it.

  No `allow/3` is issued, and none would help: a RepoServer is started by a
  DynamicSupervisor the test does not own, so there is no point at which the
  test knows which pid to allow, and one started during the test would have to
  be allowed again for every following test.

  The owner is a separate unlinked process because a RepoServer that outlives
  the test process would otherwise take the connection down with it.

  Rollback covers the database only. Key files under the data directory and
  the live RepoServers are cleaned up here: a RepoServer caches the entry map,
  rev and tid counter that the rolled-back transaction wrote, so handing one to
  the next test is exactly the leak this module exists to prevent. Key files
  need removing for the same reason, since a rolled-back row would otherwise
  still leave a file on disk for a DID no account owns.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Pesque.{Repo, RepoSupervisor, Storage}

  @doc "Checks a connection out for the calling test. Call from a test's setup block."
  def setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    keys = key_files()

    ExUnit.Callbacks.on_exit(fn ->
      stop_repos()
      Sandbox.stop_owner(owner)
      remove_keys(keys)
    end)

    :ok
  end

  defp stop_repos do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(RepoSupervisor) do
      DynamicSupervisor.terminate_child(RepoSupervisor, pid)
    end

    :ok
  end

  defp key_files, do: File.ls!(Storage.keys_dir())

  defp remove_keys(before) do
    for name <- File.ls!(Storage.keys_dir()), name not in before do
      File.rm(Path.join(Storage.keys_dir(), name))
    end

    :ok
  end
end
