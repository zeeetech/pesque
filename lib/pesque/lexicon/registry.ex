defmodule Pesque.Lexicon.Registry do
  @moduledoc """
  Every lexicon the server knows, keyed by NSID.

  Extension is a file on disk. Drop a lexicon JSON into `priv/lexicons` (the
  vendored upstream set, where `mix pesque.sync_lexicons` writes) or into
  `data/lexicons` (yours, survives an upstream refresh), and it is loaded on
  the next boot. There is no registration call, no plugin manifest and no
  config knob: a directory listing is the whole configuration.

  Both roots are read in that order, so a file in `data/lexicons` carrying an
  NSID an upstream file already uses replaces it. That is what makes
  overriding `app.bsky.feed.post` a local edit rather than a fork.

  The index is built once at boot into `:persistent_term`. Lexicons only change
  when someone edits a file, and a server that re-read 400 JSON files on every
  write would be paying for a schema check with a disk read. `reload/0` is for
  an operator with a running server; nothing on the request path calls it.
  """

  require Logger

  @vendored Path.join(:code.priv_dir(:pesque), "lexicons")
  @table __MODULE__

  @doc "The directory of lexicons shipped with the release."
  def vendored_dir, do: @vendored

  @doc "The directory of lexicons the operator added."
  def user_dir, do: Path.join(Pesque.data_dir(), "lexicons")

  @doc """
  Loads every lexicon from every root, replacing whatever was loaded before.

  A file that does not parse, or one with no `id`, is logged and skipped
  rather than raised on: one broken custom lexicon should not be the reason a
  server that was up is now down. Later roots replace earlier ones, keyed by
  the `id` each file declares rather than by where it sits, so a copy that
  moved between directories keeps its identity.
  """
  def reload do
    entries =
      [@vendored, user_dir()]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.json")))
      |> Enum.uniq()
      |> Enum.reduce(%{}, &read(&1, &2))

    :persistent_term.put(@table, entries)

    Logger.info("lexicons loaded", count: map_size(entries))
    :ok
  end

  defp read(path, acc) do
    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, %{"id" => nsid} = doc} when is_binary(nsid) ->
            Map.put(acc, nsid, doc)

          _ ->
            Logger.warning("lexicon skipped, no valid id", path: path)
            acc
        end

      {:error, _reason} ->
        Logger.warning("lexicon skipped, unreadable", path: path)
        acc
    end
  end

  @doc "Every loaded lexicon, as a map of NSID to parsed document."
  def all, do: :persistent_term.get(@table, %{})

  @doc "The document for an NSID, or nil."
  def get(nsid) when is_binary(nsid), do: Map.get(all(), nsid)
  def get(_nsid), do: nil

  @doc "The object schema a collection's records are checked against, or nil."
  def record(collection) when is_binary(collection) do
    with %{"defs" => defs} when is_map(defs) <- get(collection) do
      # The schema is the `record` key of the def whose own type is "record".
      # A collection's lexicon is named after the collection, not after the
      # record type, so this looks the collection up directly. Among the
      # vendored files exactly one names a def "record" rather than marking one
      # as a record, and it is a defs.json of definitions about records rather
      # than a collection, which is why the type is what is matched on.
      defs
      |> Enum.filter(fn {_name, def} -> def["type"] == "record" end)
      |> List.first()
      |> case do
        {_name, %{"record" => schema}} when is_map(schema) ->
          resolve(schema, get(collection), MapSet.new())

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  @doc "Whether this server holds a lexicon for a collection."
  def knows?(collection) when is_binary(collection), do: record(collection) != nil
  def knows?(_collection), do: false

  # Refs are pointers, and following them here rather than inside the validator
  # is what keeps that one pure: it takes a schema and reads no registry.
  # Without this a post's reply block, which is a com.atproto.repo.strongRef,
  # would go unchecked, and that is where the at-uri and cid formats of every
  # reply live.
  #
  # Each node is resolved against the document it came from, not the one the
  # walk started in: a #link inside a pulled-in definition means a def of that
  # definition's own lexicon, and looking it up in the collection's lexicon is
  # how a facet feature turns into an unknown_type on a perfectly good post.
  #
  # A ref naming a lexicon this server does not hold, or a definition that
  # document does not have, is left as it is. The validator accepts a ref it
  # cannot follow, so a lexicon referring to something absent degrades to that
  # subtree being unchecked rather than to writes being refused.
  defp resolve(%{"type" => "ref", "ref" => ref}, document, seen) when is_binary(ref) do
    case lookup(ref, document, seen) do
      {nil, _document} -> %{"type" => "ref", "ref" => ref}
      {target, target_document} -> resolve(target, target_document, MapSet.put(seen, ref))
    end
  end

  # A union is left as it is apart from the defs it needs to resolve its own
  # local refs against, which is the one thing the validator cannot work out
  # from the node alone.
  defp resolve(%{"type" => "union"} = node, document, _seen),
    do: Map.put(node, "defs", Map.get(document, "defs", %{}))

  defp resolve(%{"properties" => properties} = node, document, seen) when is_map(properties) do
    Map.put(
      node,
      "properties",
      Map.new(properties, fn {key, child} ->
        {key, resolve(child, document, seen)}
      end)
    )
  end

  defp resolve(%{"items" => items} = node, document, seen),
    do: Map.put(node, "items", resolve(items, document, seen))

  # Anything else has nothing inside it to follow.
  defp resolve(node, _document, _seen), do: node

  # Each answer carries the document it came from, because that is the document
  # a "#def" inside it has to be looked up in.
  #
  # A ref already being followed is left alone, so two lexicons referring to
  # each other terminate instead of resolving forever. The validator accepts a
  # ref it cannot follow, so stopping costs one unchecked subtree rather than a
  # hung boot.
  defp lookup("#" <> name, document, _seen), do: {get_in(document, ["defs", name]), document}

  defp lookup(nsid, _document, seen) do
    with false <- MapSet.member?(seen, nsid),
         {:ok, document} <- Map.fetch(all(), nsid) do
      {get_in(document, ["defs", "main"]), document}
    else
      _ -> {nil, nil}
    end
  end
end
