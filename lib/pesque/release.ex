defmodule Pesque.Release do
  @moduledoc "Release support: task bootstrap and the migration runner."

  @doc """
  Starts the application for a one-off release task.

  A release `eval` boots the VM but does not start the applications, so a task
  that reads the server identity or touches the database has to ask for them
  first. The endpoint stays down: a task runs against the data directory the
  live server already holds, and binding the port would fail.
  """
  def boot! do
    Application.put_env(:pesque, :serve, false)

    case Application.ensure_all_started(:pesque) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "the application could not start: #{inspect(reason)}"
    end
  end

  def migrate do
    if Process.whereis(Pesque.Repo) do
      run()
    else
      {:ok, _, _} = Ecto.Migrator.with_repo(Pesque.Repo, fn _repo -> run() end)
      :ok
    end
  end

  defp run do
    path = Path.join(:code.priv_dir(:pesque), "repo/migrations")
    Ecto.Migrator.run(Pesque.Repo, path, :up, all: true)
  end
end
