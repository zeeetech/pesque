defmodule Pesque.BootMigrator do
  @moduledoc """
  Supervisor child that runs migrations synchronously during startup.
  Returns `:ignore` so the tree continues to the next child only after
  the schema is current.
  """

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  def start_link do
    Pesque.Release.migrate()
    :ignore
  end
end
