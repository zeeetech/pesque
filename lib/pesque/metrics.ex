defmodule Pesque.Metrics do
  @moduledoc """
  The server's own counters, and the snapshot `/metrics` renders from.

  The shape is the one `Pesque.RateLimit` uses: one GenServer owning one
  named, public ETS table. A counter is written with `:ets.update_counter/4`
  in the caller's own process, so an event adds to its total without a
  message to anything, and the process exists to own the table and to keep
  the telemetry attachment alive, not to serve the reads.

  What is counted, and where from:

  - `pesque_http_requests_total{route,status}` - one per response the
    endpoint sends, through a handler on `[:phoenix, :endpoint, :stop]`. The
    endpoint emits that pair itself, through `Plug.Telemetry`, and its only
    metadata is the conn, so the route label is re-matched from the conn at
    stop with `Phoenix.Router.route_info/4`, which answers the path
    template. A response that an exception rendered never reaches the
    `register_before_send` the stop event fires from, so a 404 on a path
    outside every route and a 500 from a crash are not counted; every
    response a controller built is.
  - `pesque_rate_limit_rejections_total` - from `Pesque.RateLimit.hit/3`,
    when it refuses.
  - `pesque_firehose_commit_frames_total` - from `Pesque.Events.broadcast/1`,
    per `#commit` frame it pushes.

  The gauges are computed at snapshot time rather than kept current: a scrape
  is the only reader, and it can afford the registry count and the two
  indexed aggregates they take, so nothing pays to keep them fresh between
  scrapes.

  The labels are bounded by construction. `route` is a template out of the
  router (or `"other"` for a request answered before the router ran),
  `status` is a code, and no metric names a DID, a handle or an address, so
  the table cannot grow with the traffic.
  """

  use GenServer

  alias Pesque.RepoStore

  @table :pesque_metrics

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :telemetry.attach(
      {__MODULE__, :http_requests},
      [:phoenix, :endpoint, :stop],
      &__MODULE__.http_stop/4,
      nil
    )

    {:ok, nil}
  end

  @doc """
  Counts `by` more of `key`. One event is `inc/1`.

  The key is this module's to namespace: a bare atom for a plain counter, a
  `{:http, route, status}` tuple for the request counts.
  """
  @spec inc(term(), non_neg_integer()) :: :ok
  def inc(key, by \\ 1)

  def inc(key, by) when is_integer(by) and by >= 0 do
    :ets.update_counter(@table, key, {2, by}, {key, 0})
    :ok
  rescue
    # The table is gone, which only happens while the application is
    # stopping. A metric is never worth a request, so this one passes.
    ArgumentError ->
      :ok
  end

  @doc """
  Replaces the gauge stored under `key`.

  Gauges a scrape can compute itself (`Pesque.Events`' registry, the store's
  counts) are never written here; this is for one that only changes by
  event. Stored gauges ride along in `snapshot/0` under their name.
  """
  @spec set(term(), number()) :: :ok
  def set(key, value) do
    :ets.insert(@table, {{:gauge, key}, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Everything the exposition renders, as one plain map.

  Counters come off the table, the store gauges are read live, and a gauge
  `set/2` was given rides along under its name (a computed one wins if the
  names ever met). The SQL reads are one count and one aggregate over two
  small indexed tables, which is the cost a scrape can afford and no more
  than `/xrpc/_health` takes.
  """
  @spec snapshot() :: map()
  def snapshot do
    counters = counters()
    {blob_count, blob_bytes} = RepoStore.blob_totals()

    computed = %{
      # One entry per registered socket, which is what the count is.
      firehose_subscribers: Registry.lookup(Pesque.EventRegistry, :firehose) |> length(),
      accounts: RepoStore.account_count(),
      blobs_total: blob_count,
      blobs_bytes: blob_bytes
    }

    counters
    |> Map.merge(stored_gauges())
    |> Map.merge(computed)
    |> Map.put(:http_requests, http_requests())
  end

  # The endpoint's stop event. Only the conn comes with it, so the route is
  # re-matched rather than guessed from the request path: a label per real
  # path would be unbounded, and a template out of the router is not.
  @doc false
  def http_stop(_event, _measurements, %{conn: conn}, _config) do
    case conn.status do
      status when is_integer(status) ->
        key = {:http, route_label(conn), status}
        :ets.update_counter(@table, key, {2, 1}, {key, 0})
        :ok

      # A response send_resp never gave a code to cannot be counted as any
      # code. The before_send this fires from is exactly where a status
      # exists, so this branch is a guard, not a path.
      _ ->
        :ok
    end
  rescue
    # As in inc/2: the table is gone only while the node is stopping, and a
    # metric must not take a response with it.
    ArgumentError -> :ok
  end

  # route_info/4 is the public re-match the router itself dispatches with, so
  # the template here and the route that served the request are the same one.
  defp route_label(conn) do
    case conn.private do
      %{phoenix_router: router} ->
        case Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host) do
          %{route: template} -> template
          _ -> "other"
        end

      # Served before the router ran: Plug.Static's two legal documents.
      _ ->
        "other"
    end
  end

  defp counters do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{rate_limit_rejections: 0, firehose_commit_frames: 0}, fn
      {key, n}, acc when is_atom(key) -> Map.put(acc, key, n)
      _other, acc -> acc
    end)
  rescue
    ArgumentError -> %{rate_limit_rejections: 0, firehose_commit_frames: 0}
  end

  defp stored_gauges do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:gauge, key}, value}, acc -> Map.put(acc, key, value)
      _other, acc -> acc
    end)
  rescue
    ArgumentError -> %{}
  end

  defp http_requests do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:http, route, status}, n}, acc -> Map.put(acc, {route, status}, n)
      _other, acc -> acc
    end)
  rescue
    ArgumentError -> %{}
  end
end
