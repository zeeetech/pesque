defmodule Pesque.Release do
  @moduledoc "Migration runner, usable both at boot and from a release console."

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
