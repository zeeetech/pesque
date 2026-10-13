defmodule Pesque.Lexicon.Install do
  @moduledoc """
  Discovers the lexicons a checked-out repository carries and copies them into
  the operator's `data/lexicons`.

  The repository's layout is not trusted: a lexicon is any JSON file whose
  content is a lexicon document, `"lexicon" => 1` with a valid NSID in `id`.
  The `id` is the identity, not the path, because a repository's filenames do
  not map to NSID segments (`lexicons/repo/archive.json` is not a path of the
  NSID it holds). Everything that is not a lexicon, a monorepo's `package.json`
  and `tsconfig.json` included, is skipped.

  Files in the `com.atproto` namespace are skipped. Those are the schemas this
  server already vendors, and a third-party copy would shadow the vendored one
  on the next load, since `data/lexicons` is read after `priv/lexicons`.

  This is the operator-time counterpart to `mix pesque.sync_lexicons`: that
  task mirrors the upstream set into `priv/lexicons`, this installs a
  third-party set into `data/lexicons`, where it survives an upstream refresh.
  """

  # The NSID shape, the same one the permission grammar and the aggregator
  # check. Re-checked here because the NSID becomes a filename: a string with a
  # slash or a `..` in it must not travel into a path.
  @nsid_regex ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/

  @doc """
  Every lexicon document under `root`, keyed by NSID.

  `:dir` narrows the walk to a subdirectory of the checkout. With none, a
  `lexicons/` directory at the root is used when it exists (the convention
  ATProto projects follow), and the whole tree otherwise. A file that cannot
  be read, or that is not a lexicon, is skipped rather than raised on: one bad
  file in a repository must not stop the good ones from installing.
  """
  def discover(root, opts \\ []) do
    if File.dir?(root) do
      documents =
        root
        |> candidates(Keyword.get(opts, :dir))
        |> Enum.sort()
        |> Enum.reduce(%{}, &read/2)

      {:ok, documents}
    else
      {:error, {:not_a_directory, root}}
    end
  end

  @doc """
  Writes each document as `<nsid>.json` under `target`.

  Answers the NSIDs written; the first file that cannot be written stops the
  run with the reason.
  """
  def install(documents, target) do
    with :ok <- File.mkdir_p(target) do
      Enum.reduce_while(documents, {:ok, []}, fn {nsid, document}, {:ok, written} ->
        case File.write(Path.join(target, nsid <> ".json"), JSON.encode!(document)) do
          :ok -> {:cont, {:ok, [nsid | written]}}
          {:error, reason} -> {:halt, {:error, {:unwritable, nsid, reason}}}
        end
      end)
    end
  end

  # The `lexicons/` directory at the root when there is one, the whole tree
  # otherwise. Scoping to `lexicons/` keeps a monorepo's thousands of unrelated
  # JSON files out of the walk; the content check below is what actually
  # decides, this only narrows where it looks.
  defp candidates(root, nil) do
    lexicons = Path.join(root, "lexicons")
    walk(if File.dir?(lexicons), do: lexicons, else: root)
  end

  defp candidates(root, dir), do: walk(Path.join(root, dir))

  defp walk(base) do
    base
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/.git/"))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
  end

  defp read(path, acc) do
    case File.read(path) do
      {:ok, body} -> put(body, acc)
      {:error, _reason} -> acc
    end
  end

  defp put(body, acc) do
    case JSON.decode(body) do
      {:ok, %{"lexicon" => 1, "id" => nsid} = document} when is_binary(nsid) ->
        if keep?(nsid), do: Map.put(acc, nsid, document), else: acc

      _other ->
        acc
    end
  end

  defp keep?(nsid) do
    not String.starts_with?(nsid, "com.atproto.") and Regex.match?(@nsid_regex, nsid)
  end
end
