defmodule Pesque do
  @moduledoc "Top-level accessors for server-wide configuration."

  def version do
    case Application.spec(:pesque, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  def data_dir, do: Application.get_env(:pesque, :data_dir, "data")
  def mode, do: Application.get_env(:pesque, :mode, :conformant_single)
  def hostname, do: Application.get_env(:pesque, :hostname, "localhost")
  def handle_domain, do: Application.get_env(:pesque, :handle_domain, hostname())
  def port, do: Application.get_env(:pesque, :port, 4000)
  def handle, do: Application.get_env(:pesque, :handle, hostname())
  def registration, do: Application.get_env(:pesque, :registration, :closed)
end
