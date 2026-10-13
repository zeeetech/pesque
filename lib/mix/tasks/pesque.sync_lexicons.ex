defmodule Mix.Tasks.Pesque.SyncLexicons do
  @shortdoc "Downloads the upstream ATProto lexicons into priv/lexicons"

  @moduledoc """
  Refreshes `priv/lexicons` from bluesky-social/atproto.

      mix pesque.sync_lexicons

  Only the namespaces this server enforces are mirrored: `com`, `app`, `chat`
  and `tools`, the four the reference PDS bundles. Everything else upstream
  publishes (`site`, `internal`, `place`, `social`) is a third-party schema this
  server does not validate against, so shipping it would only add files nobody
  reads. A file already on disk with the same NSID is replaced, and files
  upstream no longer publishes are left alone. Downloads with `:httpc`, so this
  task starts `:inets` itself.
  """

  use Mix.Task

  @repo "bluesky-social/atproto"
  @branch "main"
  @tree "https://api.github.com/repos/#{@repo}/git/trees/#{@branch}?recursive=1"
  @raw "https://raw.githubusercontent.com/#{@repo}/#{@branch}"

  # The namespaces the server ships and therefore enforces. A lexicon upstream
  # adds under any other root is not vendored on purpose.
  @namespaces ~w(app chat com tools)

  @impl Mix.Task
  def run(_args) do
    {:ok, _apps} = Application.ensure_all_started(:inets)

    target = Pesque.Lexicon.Registry.vendored_dir()
    File.mkdir_p!(target)

    case list() do
      {:ok, paths} -> write_all(target, paths)
      {:error, reason} -> Mix.raise("could not list upstream lexicons: #{reason}")
    end
  end

  # The tree API rather than a tarball: no unpacking, and the paths come back
  # filtered to the namespaces this server vendors.
  defp list do
    case get(@tree) do
      {:ok, body} ->
        with {:ok, %{"tree" => tree}} <- JSON.decode(body) do
          {:ok,
           tree
           |> Enum.filter(&bundled?/1)
           |> Enum.map(& &1["path"])}
        else
          {:error, _reason} -> {:error, "unexpected response"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A blob under `lexicons/<namespace>/...` whose namespace is one this server
  # vendors. The tree API returns directories too, and everything the server
  # does not ship is dropped here rather than written and never read.
  defp bundled?(%{"type" => "blob", "path" => "lexicons/" <> rest}) do
    [namespace | _] = String.split(rest, "/", parts: 2)
    namespace in @namespaces
  end

  defp bundled?(_entry), do: false

  defp write_all(target, paths) do
    {written, failed} = Enum.split_with(paths, &fetch!(target, &1))

    Mix.shell().info("""
    #{length(paths)} lexicons, #{length(written)} written, #{length(failed)} failed.
    Commit priv/lexicons to keep the vendored set.
    """)

    if failed != [], do: Mix.raise("#{length(failed)} lexicons could not be downloaded")
  end

  defp fetch!(target, path) do
    destination = Path.join(target, String.replace_prefix(path, "lexicons/", ""))
    File.mkdir_p!(Path.dirname(destination))

    case get("#{@raw}/#{path}") do
      {:ok, body} ->
        File.write!(destination, body)
        true

      {:error, reason} ->
        Mix.shell().info("  failed #{path}: #{reason}")
        false
    end
  end

  defp get(url) do
    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [timeout: 30_000, connect_timeout: 10_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, body}} -> {:error, "HTTP #{status}: #{body}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
