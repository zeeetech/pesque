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

  # A union keeps its own defs, which is the one thing the validator cannot
  # work out from the node alone, and gains a resolved schema per member ref.
  #
  # Without the members a union body went unchecked entirely: the validator saw
  # a $type naming an NSID, had no schema to hand, and accepted it on its name.
  # So a post's embed, a labels block or a site.standard.document content took
  # any shape at all, and the lexicon author and the submitter are independent
  # parties.
  #
  # A ref is followed with itself added to `seen`, so a union whose members
  # point back at the document holding it terminates instead of resolving
  # forever.
  defp resolve(%{"type" => "union"} = node, document, seen) do
    node
    |> Map.put("defs", Map.get(document, "defs", %{}))
    |> put_variants(document, seen)
  end

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

  # A ref naming a lexicon this server does not hold contributes no variant, so
  # the validator finds nothing to check that member against and accepts it on
  # its name. That is the same degradation a dangling ref gets anywhere else.
  defp put_variants(node, document, seen) do
    variants =
      [node["ref"] | Map.get(node, "refs", [])]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn ref ->
        case lookup(ref, document, seen) do
          {nil, _document} ->
            []

          {target, target_document} ->
            [{ref, resolve(target, target_document, MapSet.put(seen, ref))}]
        end
      end)

    Map.put(node, "variants", Map.new(variants))
  end

  # Each answer carries the document it came from, because that is the document
  # a "#def" inside it has to be looked up in.
  #
  # A ref already being followed is left alone, so two lexicons referring to
  # each other terminate instead of resolving forever. The validator accepts a
  # ref it cannot follow, so stopping costs one unchecked subtree rather than a
  # hung boot.
  defp lookup(ref, document, seen) do
    if MapSet.member?(seen, ref) do
      {nil, document}
    else
      foreign(ref, document)
    end
  end

  # "#name" is a def of the document the ref came from; "nsid" is that
  # lexicon's main; "nsid#name" is a def of another lexicon, which is how a post
  # names "com.atproto.label.defs#selfLabels".
  defp foreign("#" <> name, document),
    do: {get_in(document, ["defs", name]), document}

  defp foreign(ref, _document) do
    case String.split(ref, "#", parts: 2) do
      [nsid] -> def_of(nsid, "main")
      [nsid, name] -> def_of(nsid, name)
    end
  end

  defp def_of(nsid, def_name) do
    case Map.fetch(all(), nsid) do
      {:ok, document} -> {get_in(document, ["defs", def_name]), document}
      :error -> {nil, nil}
    end
  end
end
