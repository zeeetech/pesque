defmodule Pesque.Migrate.Runner do
  @moduledoc """
  Runs a move off-request, so a page can watch it instead of a terminal.

  A move takes minutes: the repo import runs as long as the account's
  history, and the PLC step waits on a code the account holder reads out of
  an email. A request process answers in seconds and its client moves on, so
  the move cannot run inside one. It runs here, under
  `Pesque.Migrate.Supervisor`, and the row in `Pesque.Migrate.Jobs` is what a
  page reads while it runs.

  The PLC code is handed to the running process as a message rather than
  written into the row. The page has no session, so the token a person holds
  is the whole capability, and anything the row carries is readable by
  whoever holds it; a code that signs identity operations is not one of those
  things. `submit_code/2` answers `{:error, :not_running}` when nothing is
  registered under the token, which is also what it answers once the move has
  finished, failed or never started.

  A restart takes the task and its registration down with the node, so a row
  that still says a move is running after a boot is one nothing is answering.
  The boot sweep, `Pesque.Migrate.Jobs.reap_interrupted/0`, is what marks
  those failed so the operator starts the move again.
  """

  require Logger

  alias Pesque.Migrate
  alias Pesque.Migrate.Job
  alias Pesque.Migrate.Jobs

  @registry Pesque.Migrate.Registry

  # The reference PDS gives its emailed PLC code 15 minutes, so a move that
  # waits longer than that answers no code at all, which is the failure the
  # row reports.
  @code_timeout 15 * 60 * 1000

  @doc """
  Starts a move and answers :ok, whatever the move goes on to do.

  The outcome lands in the row, not in this answer.
  """
  @spec start(Job.t(), keyword()) :: :ok
  def start(%Job{} = job, opts) do
    Task.Supervisor.start_child(Pesque.Migrate.Supervisor, fn -> run(job, opts) end)

    :ok
  end

  @doc """
  Hands a PLC code to the move a token names.

  Nothing registered under the token means no move is waiting for one: it
  finished, failed or never started, and the code has nowhere to go.

  The row moves back to `:running` here, in the caller, rather than in the
  task that takes the code off its mailbox: the form answers with a redirect,
  and the page it lands on polls only while the row says `:running`, so a row
  still on `:awaiting_code` when that redirect lands would render the form a
  second time. The task re-asserts the same phase once it has the code, so a
  code handed in before the prompt opened still leaves the row running.
  """
  @spec submit_code(term(), term()) :: :ok | {:error, :not_running}
  def submit_code(token, code) do
    case Registry.lookup(@registry, token) do
      [{pid, _value}] ->
        send(pid, {:plc_code, code})
        resume(token)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  # Only a row waiting on the code moves: one already running needs nothing,
  # and a row that finished is not reopened by a code that arrived too late.
  defp resume(token) do
    case Jobs.get(token) do
      %Job{phase: :awaiting_code} = job -> Jobs.advance(job, :running)
      _other -> :ok
    end
  end

  # Registered before the move starts, so a code the page submits from the
  # first moment has somewhere to go. The move runs inside a catch, so a task
  # that throws, exits or raises still marks its row failed rather than
  # leaving one that says a move is running when nothing is.
  defp run(%Job{} = job, opts) do
    {:ok, _owner} = Registry.register(@registry, job.token, nil)

    result =
      try do
        Migrate.run(Keyword.put(opts, :prompt, fn _message -> wait(job) end))
      catch
        kind, value -> {kind, value}
      end

    finish(job, result)
  end

  # The row moves to :awaiting_code before the wait, so a page watching the
  # move sees the wait it is in. A code that never arrives makes the prompt
  # answer nil, which Migrate turns into {:error, :plc_code_missing}. A code
  # that arrives puts the row back on :running: the move is working again, and
  # the page that watches a running move is the one that polls. This is the
  # task's own copy of the move submit_code/2 makes in the request, so a code
  # that reached the mailbox before the prompt opened is not left on the form.
  defp wait(%Job{} = job) do
    Jobs.advance(job, :awaiting_code)

    receive do
      {:plc_code, code} when is_binary(code) and code != "" ->
        Jobs.advance(job, :running)
        code
    after
      @code_timeout -> nil
    end
  end

  defp finish(%Job{} = job, :ok) do
    Jobs.advance(job, :done)
  end

  defp finish(%Job{} = job, {:error, reason}) do
    Logger.error("migration failed", handle: job.handle, reason: inspect(reason))
    Jobs.advance(job, :failed, failure(reason))
  end

  # A throw, an exit or a raise out of the move: not a reason the row has a
  # sentence for, but a move that ended all the same.
  defp finish(%Job{} = job, other) do
    Logger.error("migration ended unexpectedly", handle: job.handle, reason: inspect(other))
    Jobs.advance(job, :failed, "unknown")
  end

  # The page renders one sentence per code, so the vocabulary belongs to the
  # row and not to the reason: a stable string the copy can name, however the
  # reason underneath is shaped.
  defp failure(:invalid_invite_code), do: "invalid_invite_code"
  defp failure(:invite_code_required), do: "invite_code_required"
  defp failure(:handle_not_available), do: "handle_not_available"
  defp failure(:handle_not_under_domain), do: "handle_not_under_domain"
  defp failure(:email_taken), do: "email_taken"
  defp failure(:password_too_short), do: "password_too_short"
  defp failure(:missing_fields), do: "missing_fields"
  defp failure(:plc_code_missing), do: "code_timeout"
  defp failure({:old_pds_status, 401, _message}), do: "old_pds_unauthorized"
  defp failure({:old_pds_status, _status, _message}), do: "old_pds_rejected"
  defp failure({:old_pds_status, 401}), do: "old_pds_unauthorized"
  defp failure({:old_pds_status, _status}), do: "old_pds_rejected"
  defp failure({:old_pds_unreachable, _detail}), do: "old_pds_unreachable"

  # What a move can answer, the person can act on. The reasons left out
  # ({:missing_option, _key}, :account_missing, :invalid_response) are this
  # server's own bugs, and they stay on the generic sentence the catch-all
  # hands over.
  defp failure(:invalid_handle), do: "invalid_handle"
  defp failure(:disallowed_handle), do: "disallowed_handle"
  defp failure(:account_exists), do: "account_exists"

  # A refused sign-in and a 401 from the old server are the same answer to the
  # person: the credentials did not open the account.
  defp failure(:invalid_credentials), do: "old_pds_unauthorized"

  defp failure(:too_large), do: "too_large"

  defp failure(_reason), do: "unknown"
end
