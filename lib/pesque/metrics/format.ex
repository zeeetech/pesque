defmodule Pesque.Metrics.Format do
  @moduledoc """
  The Prometheus text exposition of a snapshot, as a pure function.

  `render/1` takes the plain map `Pesque.Metrics.snapshot/0` builds and
  answers the `text/plain` body a scraper reads. It touches nothing: no
  table, no clock, no database, so a test can call it with a literal and a
  scrape of a live server differs from it only in the numbers.

  The catalogue below is the whole series the exposition carries, in the
  order it carries them. A snapshot may hold keys the catalogue does not
  name; they are not rendered, because a series that appears without a type
  line and a help string is one an operator has to guess about.

  Label values are escaped the way the exposition format requires
  (backslash, double quote, line feed), and the `route` label is always a
  route template rather than a request path, so the label set stays bounded
  no matter what the traffic looks like.
  """

  # name, help, and the snapshot key the value is read from.
  @counters [
    {"pesque_rate_limit_rejections_total",
     "Requests the rate limiter refused across every bucket.", :rate_limit_rejections},
    {"pesque_firehose_commit_frames_total", "Commit frames pushed to the firehose log.",
     :firehose_commit_frames}
  ]

  @gauges [
    {"pesque_firehose_subscribers", "Sockets currently subscribed to the firehose.",
     :firehose_subscribers},
    {"pesque_accounts_total", "Accounts hosted on this server, in any state.", :accounts},
    {"pesque_blobs_total", "Blob rows in the repository store.", :blobs_total},
    {"pesque_blobs_bytes", "Blob bytes the repository store records.", :blobs_bytes}
  ]

  @doc """
  The exposition of one snapshot. Every counter and gauge is rendered even
  when the snapshot has no number for it, because a missing series and a
  zero one mean different things to a scraper's queries: absent is "no data",
  zero is "nothing happened".
  """
  @spec render(map()) :: String.t()
  def render(snapshot) when is_map(snapshot) do
    [
      render_http(Map.get(snapshot, :http_requests, %{})),
      render_each(@counters, snapshot, "counter"),
      render_each(@gauges, snapshot, "gauge")
    ]
    |> IO.iodata_to_binary()
  end

  defp render_http(http) do
    help =
      [
        "# HELP pesque_http_requests_total HTTP requests answered, by route and status.\n",
        "# TYPE pesque_http_requests_total counter\n"
      ]

    samples =
      http
      |> Enum.sort()
      |> Enum.map(fn {{route, status}, count} ->
        "pesque_http_requests_total{route=#{escape(route)},status=#{escape(Integer.to_string(status))}} " <>
          Integer.to_string(count) <> "\n"
      end)

    [help | samples]
  end

  defp render_each(series, snapshot, type) do
    Enum.map(series, fn {name, help, key} ->
      [
        "# HELP ",
        name,
        " ",
        String.replace(help, "\n", " "),
        "\n# TYPE ",
        name,
        " ",
        type,
        "\n",
        name,
        " ",
        to_string(Map.get(snapshot, key, 0)),
        "\n"
      ]
    end)
  end

  # The exposition format escapes a label value's backslashes, double quotes
  # and line feeds. Backslash first, or the escapes this adds would be
  # escaped a second time.
  defp escape(value) do
    quoted =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\"", "\\\"")

    ~s("#{quoted}")
  end
end
