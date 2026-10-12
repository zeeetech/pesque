defmodule Pesque.Migrate.Jobs do
  @moduledoc """
  The rows a move off-request leaves behind.

  A move runs in a task (`Pesque.Migrate.Runner`), so the row is the only
  state a page can watch and the only thing that outlives the worker. No
  credential is stored in a row, and the token is the whole capability for
  reading one and answering it.
  """

  import Ecto.Query

  alias Pesque.Migrate.Job
  alias Pesque.Repo

  @doc """
  Opens a move and answers its row.

  The token is what a person holds, so it is 16 fresh bytes url-encoded: it
  names the row and everything a page may do with the move. Answers
  `{:ok, %Job{}}` or `{:error, changeset}`.
  """
  @spec open(String.t(), String.t()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def open(handle, old_pds) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    %{token: token, handle: handle, old_pds: old_pds}
    |> Job.changeset()
    |> Repo.insert()
  end

  @doc """
  The move a token names, or nil.

  A token that is not a binary names nothing rather than raising: it comes
  off a URL a person holds, so anything at all can arrive.
  """
  @spec get(term()) :: Job.t() | nil
  def get(token) when is_binary(token), do: Repo.get_by(Job, token: token)
  def get(_token), do: nil

  @doc """
  Writes a phase onto a move, with the error that ended it when it failed.

  Answers `{:ok, job}` or `{:error, changeset}`.
  """
  @spec advance(Job.t(), :running | :awaiting_code | :done | :failed, String.t() | nil) ::
          {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def advance(%Job{} = job, phase, error \\ nil) do
    job
    |> Job.phase_changeset(phase, error)
    |> Repo.update()
  end

  @doc """
  Marks every move that says it is still going as failed, and answers the
  count.

  A move runs in a task, and a restart takes it down with the node, so
  nothing is running at boot and a row that says otherwise is one the
  operator starts again. The rows are loaded and advanced one by one rather
  than written with update_all/2, so the enum dumping stays the changeset's
  job.
  """
  @spec reap_interrupted() :: non_neg_integer()
  def reap_interrupted do
    from(j in Job, where: j.phase in [:running, :awaiting_code])
    |> Repo.all()
    |> Enum.count(fn job -> match?({:ok, _}, advance(job, :failed, "interrupted")) end)
  end
end
