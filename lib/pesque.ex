defmodule Pesque do
  @moduledoc "Top-level accessors for server-wide configuration."

  def version do
    case Application.spec(:pesque, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  The public base URL clients are told to reach this server at.

  Taken from the endpoint's url config rather than from hostname and port,
  because the advertised scheme and port are the proxied ones and not the
  ones this process listens on.
  """
  def base_url do
    url = Application.get_env(:pesque, PesqueWeb.Endpoint, []) |> Keyword.get(:url, [])
    scheme = Keyword.get(url, :scheme, "https")
    host = Keyword.get(url, :host, hostname())
    default_port = if scheme == "https", do: 443, else: 80
    port = Keyword.get(url, :port, default_port)
    authority = if port == default_port, do: host, else: "#{host}:#{port}"

    "#{scheme}://#{authority}"
  end

  def data_dir, do: Application.get_env(:pesque, :data_dir, "data")
  def mode, do: Application.get_env(:pesque, :mode, :conformant_single)
  def hostname, do: Application.get_env(:pesque, :hostname, "localhost")
  def handle_domain, do: Application.get_env(:pesque, :handle_domain, hostname())
  def port, do: Application.get_env(:pesque, :port, 4000)
  def handle, do: Application.get_env(:pesque, :handle, hostname())
  def registration, do: Application.get_env(:pesque, :registration, :closed)
end
