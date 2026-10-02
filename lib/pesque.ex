defmodule Pesque do
  @moduledoc "Top-level accessors for server-wide configuration."

  def version do
    case Application.spec(:pesque, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  def data_dir, do: Application.get_env(:pesque, :data_dir, "data")
  def hostname, do: Application.get_env(:pesque, :hostname, "localhost")
  def handle, do: Application.get_env(:pesque, :handle, hostname())
end
