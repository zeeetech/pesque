defmodule Pesque.Lexicon.AggregatorResolver do
  @moduledoc """
  The permission sets this server does not hold locally, fetched from the
  operator-configured aggregator.

  Inactive until `lexicon_aggregator` is configured: with no base URL every
  non-local set is simply unresolvable, which is the honest answer rather than
  a guess about where to ask. The URL convention is NSID segments as a path
  under the base, mirroring the on-disk tree `sync_lexicons` produces: a base
  of `https://sets.example.com` asks for
  `https://sets.example.com/app/bsky/authFullApp.json`.

  The fetch goes through `Pesque.OAuth.Fetch.get/2`, so it inherits the one
  outbound path this server already has: HTTPS only, addresses checked against
  the public internet, no redirects followed, and a byte cap. Before the path
  is built the NSID is checked against the same shape the permission grammar
  uses, so a traversal-shaped string has nothing to travel in.

  The document is only accepted when it is a JSON object, declares
  `"lexicon" => 1` and carries the `id` that was asked for: a document that
  answers for another NSID is not this set, whatever it contains.
  """

  @behaviour Pesque.Lexicon.Resolver

  # The same NSID shape the permission grammar checks an include's positional
  # against, re-checked here because this side of the boundary builds a URL
  # path out of it.
  @nsid_regex ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/

  # One permission-set document. The client metadata cap is 10 MiB because a
  # metadata document is arbitrary JSON; a set is a lexicon, and 1 MiB is
  # generous for one.
  @max_bytes 1024 * 1024

  @impl true
  def resolve(nsid) when is_binary(nsid) do
    base = Pesque.lexicon_aggregator()

    with true <- is_binary(base),
         :ok <- nsid?(nsid),
         {:ok, uri} <- uri(base, nsid),
         {:ok, 200, _headers, body} <- Pesque.OAuth.Fetch.get(uri, @max_bytes) do
      decode(body, nsid)
    else
      # No aggregator is configured: there is nowhere to ask.
      false -> {:error, :no_aggregator}
      :error -> {:error, :invalid_nsid}
      {:ok, _status, _headers, _body} -> {:error, :aggregator_status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp nsid?(nsid) do
    if Regex.match?(@nsid_regex, nsid), do: :ok, else: :error
  end

  defp uri(base, nsid) do
    path = String.replace(nsid, ".", "/")
    URI.new(base <> "/" <> path <> ".json")
  end

  defp decode(body, nsid) do
    with {:ok, document} when is_map(document) <- JSON.decode(body),
         1 <- Map.get(document, "lexicon"),
         ^nsid <- Map.get(document, "id") do
      {:ok, document}
    else
      {:error, reason} -> {:error, {:invalid_json, reason}}
      _other -> {:error, :not_the_set}
    end
  end
end
