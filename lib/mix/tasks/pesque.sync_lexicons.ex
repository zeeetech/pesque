defmodule Mix.Tasks.Pesque.SyncLexicons do
  @shortdoc "Downloads the upstream ATProto lexicons into priv/lexicons"

  @moduledoc """
  Refreshes `priv/lexicons` from bluesky-social/atproto.

      mix pesque.sync_lexicons

  This is the only thing that touches the vendored tree, and it is never
  needed to add a lexicon of your own. Drop a file in `data/lexicons` and
  restart; it is read alongside the vendored ones, so a sync cannot overwrite
  it.

  A file already on disk with the same NSID is replaced, so re-syncing is
  idempotent. Files under `priv/lexicons` that upstream does not publish are
  left alone rather than deleted, because a reader may have added one to the
  vendored tree instead of to `data/lexicons`.

  Downloads with `:httpc`, which is why this task starts `:inets` itself. The
  server never makes outbound requests, so nothing else in it does.
  """

  use Mix.Task

  @repo "bluesky-social/atproto"
  @branch "main"
  @tree "https://api.github.com/repos/#{@repo}/git/trees/#{@branch}?recursive=1"
  @raw "https://raw.githubusercontent.com/#{@repo}/#{@branch}"

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
  # already filtered to the lexicons directory.
  defp list do
    case get(@tree) do
      {:ok, body} ->
        with {:ok, %{"tree" => tree}} <- JSON.decode(body) do
          {:ok,
           tree
           |> Enum.filter(&match?(%{"path" => "lexicons/" <> _, "type" => "blob"}, &1))
           |> Enum.map(& &1["path"])}
        else
          {:error, _reason} -> {:error, "unexpected response"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, body}} -> {:error, "HTTP #{status}: #{body}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
