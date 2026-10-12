defmodule Pesque.OAuth.PermissionSets do
  @moduledoc """
  Permission sets: resolving the document an `include:` grant names, and
  expanding it into the concrete permissions it stands for.

  The pure half answers "what does this set mean": `expand/2` walks the
  document's members through `Permission.from_set_member/1`, fills the
  audiences a member inherited from the `include:` that invoked it, and drops
  everything the grammar cannot take, keeping the set's own namespace as the
  only authority over the resources it names. `set_display/2` is the consent
  page's label for a set.

  The shell half is `resolve/1`: the local registry first, then the cache, then
  the aggregator, with the staleness semantics the specification sets - a
  cached document is current for a day, is served past that when a refresh
  fails, and is gone entirely after ninety days except to a token refresh,
  which may keep an existing session on the last answer it ever got.

  `include:` never covers anything on its own (`Permission.covers?/2` answers
  false for it); everything an `include:` grants arrives through
  `resolve_and_expand/2`, which is what issuance runs and what turns the
  include grant into concrete permissions before they are stored on a token.
  """

  require Logger

  alias Pesque.Lexicon.LocalResolver
  alias Pesque.OAuth.Permission
  alias Pesque.OAuth.PermissionSets.Cache

  # A cached document is served without a fetch for a day, and stops being
  # served at all after ninety days - except to a refresh holding
  # allow_expired, and except that the cache's own sweep uses the same number.
  @fresh_ms 24 * 60 * 60 * 1000

  @doc """
  Resolves a permission set by NSID.

  The local registry is always authoritative and never cached. A cache hit
  within its freshness window is answered as it stands; a stale one is
  refreshed through the aggregator, whose success replaces the row and whose
  failure leaves the stale answer standing, exactly the specification's
  stale-then-refresh-else-fallback. A row past the ninety-day expiration is
  refetched like a miss, and on a failed fetch is still served to a caller
  holding `allow_expired: true` - the token-refresh path - so an existing
  session outlives the expiration. A set that is nowhere and cannot be
  fetched answers `{:error, {:unresolved_permission_set, nsid}}`.
  """
  @spec resolve(binary(), keyword()) ::
          {:ok, document :: map()} | {:error, {:unresolved_permission_set, binary()}}
  def resolve(nsid, opts \\ []) when is_binary(nsid) do
    case LocalResolver.resolve(nsid) do
      {:ok, document} ->
        {:ok, document}

      {:error, _reason} ->
        from_cache(nsid, opts)
    end
  end

  defp from_cache(nsid, opts) do
    now = System.system_time(:millisecond)

    case Cache.get(nsid) do
      nil ->
        fetch(nsid)

      {document, fetched_at} ->
        age = now - fetched_at

        cond do
          age <= @fresh_ms ->
            {:ok, document}

          age > Cache.expiration_ms() ->
            refetch(nsid, document, opts)

          true ->
            refresh_stale(nsid, document)
        end
    end
  end

  # The aggregator is looked up per call, not once at boot: the seam a test
  # stands a fake into is this application env, and the real implementation is
  # the SSRF-guarded fetcher.
  defp aggregator,
    do: Application.get_env(:pesque, :lexicon_resolver, Pesque.Lexicon.AggregatorResolver)

  defp refresh_stale(nsid, document) do
    case aggregator().resolve(nsid) do
      {:ok, fresh} ->
        Cache.put(nsid, fresh)
        {:ok, fresh}

      # The stale answer is what the set last meant, and the specification has
      # it served when the refresh fails rather than failing the request.
      {:error, _reason} ->
        {:ok, document}
    end
  end

  defp refetch(nsid, document, opts) do
    case aggregator().resolve(nsid) do
      {:ok, fresh} ->
        Cache.put(nsid, fresh)
        {:ok, fresh}

      {:error, _reason} ->
        if opts[:allow_expired] do
          {:ok, document}
        else
          {:error, {:unresolved_permission_set, nsid}}
        end
    end
  end

  defp fetch(nsid) do
    case aggregator().resolve(nsid) do
      {:ok, document} ->
        Cache.put(nsid, document)
        {:ok, document}

      {:error, _reason} ->
        {:error, {:unresolved_permission_set, nsid}}
    end
  end

  @doc """
  Resolves every `include:` in a grant list and replaces it with its expansion.

  The other grants pass through untouched, so the answer is the concrete
  permissions the token will carry: a set's expansion rides where the include
  sat, in the order the document listed its members. One unresolvable set
  fails the whole answer; the caller decides what that means (PAR refuses the
  request, an exchange refuses the token, a refresh holding `allow_expired`
  has already had its last-resort answer inside `resolve/2`).
  """
  @spec resolve_and_expand([Permission.t()], keyword()) ::
          {:ok, [Permission.t()]} | {:error, {:unresolved_permission_set, binary()}}
  def resolve_and_expand(grants, opts \\ []) do
    answer =
      Enum.reduce_while(grants, {:ok, []}, fn
        %Permission{resource: :include} = include, {:ok, acc} ->
          case resolve(include.nsid, opts) do
            {:ok, document} ->
              warn_bad_document(include.nsid, document)
              {:cont, {:ok, Enum.reverse(expand(include, document), acc)}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        grant, {:ok, acc} ->
          {:cont, {:ok, [grant | acc]}}
      end)

    case answer do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp warn_bad_document(nsid, document) do
    case main(document) do
      {:ok, _main} ->
        :ok

      :error ->
        Logger.warning(
          "the resolved permission set is not a permission-set document, so it grants nothing",
          nsid: nsid
        )
    end
  end

  @doc """
  The concrete permissions one `include:` grant stands for, from its document.

  Pure: the include grant (its NSID and audience) and the resolved lexicon in,
  permissions out. Members the grammar cannot take are dropped without error,
  the way the specification reads a set it does not understand; an
  `inheritAud` member takes the include's audience, and one invoked with no
  audience to inherit has none to act on and is ignored.

  No recursion: a set's members are permissions only, and a member of any
  other type - an include inside a set among them - is skipped by
  `Permission.from_set_member/1`.
  """
  @spec expand(Permission.t(), map()) :: [Permission.t()]
  def expand(%Permission{resource: :include, nsid: nsid, aud: aud}, set_doc) do
    case main(set_doc) do
      {:ok, %{"permissions" => members}} when is_list(members) ->
        Enum.flat_map(members, &member_grants(&1, nsid, aud))

      _other ->
        []
    end
  end

  # The document's main definition, and only when it says it is a set: a
  # lexicon of any other shape contributes nothing, and the shell logs the
  # document that said so.
  defp main(%{"defs" => %{"main" => %{"type" => "permission-set"} = main}}), do: {:ok, main}
  defp main(_document), do: :error

  defp member_grants(member, set_nsid, include_aud) do
    case Permission.from_set_member(member) do
      {:ok, grant} -> authorized(grant, set_nsid, include_aud)
      :skip -> []
    end
  end

  # A set may only name resources its own namespace is authoritative for: the
  # set's NSID less its last segment, as a whole-segment prefix of every
  # collection and method it references. A member outside it is dropped with a
  # warning, because the set's author and the referenced namespace's owner are
  # different parties, and only the owner of a namespace decides what may act
  # on it.
  defp authorized(grant, set_nsid, include_aud) do
    case Enum.find(references(grant), &(not namespace_allows?(set_nsid, &1))) do
      nil ->
        inherit_aud(grant, include_aud)

      ref ->
        Logger.warning("permission set member names a resource outside the set's namespace",
          set: set_nsid,
          ref: ref
        )

        []
    end
  end

  defp references(%Permission{resource: :repo, collection: collections}), do: collections
  defp references(%Permission{resource: :rpc, lxm: lxms}), do: lxms

  # Only an rpc member can carry an inherited audience, and `nil` here is
  # `inheritAud` speaking: filled from the include, or, with no audience on the
  # include, ignored as the specification says. A member that already named an
  # audience - the "*" a set carries itself - keeps it.
  defp inherit_aud(%Permission{resource: :rpc, aud: nil}, nil), do: []

  defp inherit_aud(%Permission{resource: :rpc, aud: nil} = grant, aud),
    do: [%Permission{grant | aud: aud}]

  defp inherit_aud(grant, _include_aud), do: [grant]

  @doc """
  Whether a permission set may name `ref_nsid`.

  The set's authority is every segment of its own NSID but the last, and the
  reference must begin with those segments as whole segments:

      app.example.feed.authOnlyPost -> app.example.feed.post      true
      app.example.feed.authOnlyPost -> app.example.actor.profile  false
      app.example.authFull          -> app.example.feed.post      true
  """
  @spec namespace_allows?(binary(), binary()) :: boolean()
  def namespace_allows?(set_nsid, ref_nsid) do
    List.starts_with?(String.split(ref_nsid, "."), authority(set_nsid))
  end

  defp authority(nsid), do: nsid |> String.split(".") |> Enum.drop(-1)

  @doc """
  The title and detail a consent page shows for a set.

  A set may carry localized `title:lang` and `detail:lang` objects keyed by
  language tag; when `lang` is present and one of those entries carries
  exactly the request's primary tag, it is shown, and the base fields answer
  otherwise. Nothing is negotiated beyond that: the document carries what its
  author wrote, and pesque does not invent a fallback for every header a
  browser sends.
  """
  @spec set_display(map(), binary() | nil) :: %{title: binary(), detail: binary()}
  def set_display(set_doc, lang) do
    case main(set_doc) do
      {:ok, main} ->
        %{title: localize(main, "title", lang), detail: localize(main, "detail", lang)}

      :error ->
        %{title: "", detail: ""}
    end
  end

  defp localize(main, field, lang) do
    localized = lang && Map.get(main, field <> ":lang")
    match = is_map(localized) && Map.get(localized, lang)

    if is_binary(match),
      do: match,
      else: base(main, field)
  end

  defp base(main, field) do
    case Map.get(main, field) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end
end
