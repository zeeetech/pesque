defmodule Pesque.Release do
  @moduledoc "Migration runner, usable both at boot and from a release console."

  def migrate do
    path = Path.join(:code.priv_dir(:pesque), "repo/migrations")
    Ecto.Migrator.run(Pesque.Repo, path, :up, all: true)
  end
end
