defmodule Pesque.RepoSupervisorTest do
  @moduledoc """
  `ensure_started/1` answers a pid that is alive at the moment it answers.

  The Registry reaps a dead process's entry asynchronously, so a restart
  right after a stop can catch the gap where the entry still names the
  stopped pid, and the caller's next call would fail with `:noproc`.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.RepoServer
  alias Pesque.RepoSupervisor

  test "returns a live server right after a stop, without waiting" do
    user = create_repo_account("supervisor")
    {:ok, pid} = RepoSupervisor.ensure_started(user.did)

    assert {:ok, :stopped} = RepoServer.stop(user.did)

    # Deliberately no wait: the registry entry may still name the stopped pid.
    assert {:ok, fresh} = RepoSupervisor.ensure_started(user.did)

    assert fresh != pid
    assert Process.alive?(fresh)
    assert is_map(RepoServer.entries(fresh))
  end
end
