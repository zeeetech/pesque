defmodule Pesque do
  @moduledoc "Top-level accessors for server-wide configuration."

  @doc "The application version, or \"dev\" when it is not loaded from a release."
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

  @doc "The PDS endpoint published in DID documents and PLC operations."
  def service_endpoint, do: base_url()

  @doc "Where the repo store, keys and database live. A relative path is relative to the cwd."
  def data_dir, do: Application.get_env(:pesque, :data_dir, "data")

  @doc "The DID mode: :conformant_single or :path_multi."
  def mode, do: Application.get_env(:pesque, :mode, :conformant_single)

  @doc "The DID method accounts are minted with: :web (the default) or :plc."
  def identity, do: Application.get_env(:pesque, :identity, :web)

  @doc "The PLC directory base URL. Only read under PDS_IDENTITY=plc."
  def plc_directory, do: Application.get_env(:pesque, :plc_directory, "https://plc.directory")

  @doc "Relay base URLs to ask for a crawl at boot. Empty means ask nobody."
  def crawlers, do: Application.get_env(:pesque, :crawlers, [])

  @doc "The host this server is reached at, without scheme or port."
  def hostname, do: Application.get_env(:pesque, :hostname, "localhost")

  @doc "The domain accounts get handles under. Defaults to the hostname."
  def handle_domain, do: Application.get_env(:pesque, :handle_domain, hostname())

  @doc "The port this process listens on. The advertised one is base_url/0's business."
  def port, do: Application.get_env(:pesque, :port, 4000)

  @doc "Whether self-service account creation is open or requires an invite."
  def registration, do: Application.get_env(:pesque, :registration, :closed)

  @doc """
  The largest blob uploadBlob accepts, in bytes.

  5 MiB by default, which is what the reference PDS advertises and what an
  operator sizing a disk budget expects to find. One number, read by both the
  upload path and describeServer, so the advertised cap cannot be a different
  cap from the enforced one.
  """
  def blob_max_bytes, do: Application.get_env(:pesque, :blob_max_bytes, 5 * 1024 * 1024)

  @doc """
  The largest repo importRepo accepts, in bytes.

  100 MiB by default, which is a whole repo rather than one record and still a
  number an operator can size against. A CAR is read into memory to be decoded,
  so this is the bound on what one authenticated import can make this server
  allocate, and it is configurable for the same reason the blob cap is.
  """
  def repo_import_max_bytes,
    do: Application.get_env(:pesque, :repo_import_max_bytes, 100 * 1024 * 1024)
end
