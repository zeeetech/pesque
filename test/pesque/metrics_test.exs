defmodule Pesque.MetricsTest do
  @moduledoc """
  The collector's contract: what `inc/1,2` and `set/2` put in the table is
  what the snapshot answers, the gauges a scrape computes are in it, and the
  config key that turns `/metrics` on is one the server reads.
  """

  use ExUnit.Case, async: false

  alias Pesque.Config
  alias Pesque.Metrics

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "inc/1,2 counts what the caller reports, under its own key" do
    key = :"counter_#{System.unique_integer([:positive])}"

    Metrics.inc(key, 2)
    Metrics.inc(key)

    assert Metrics.snapshot()[key] == 3
  end

  test "a gauge set/2 was given rides along in the snapshot under its name" do
    key = :"gauge_#{System.unique_integer([:positive])}"

    Metrics.set(key, 9)

    assert Metrics.snapshot()[key] == 9
  end

  test "http counters are keyed by route and status" do
    route = "/xrpc/pesque.test.#{System.unique_integer([:positive])}"

    Metrics.inc({:http, route, 200}, 4)

    assert Metrics.snapshot().http_requests[{route, 200}] == 4
  end

  test "the snapshot always carries the gauges the exposition renders" do
    snapshot = Metrics.snapshot()

    assert is_integer(snapshot.rate_limit_rejections)
    assert is_integer(snapshot.firehose_commit_frames)
    assert is_integer(snapshot.firehose_subscribers)
    assert is_integer(snapshot.accounts)
    assert is_integer(snapshot.blobs_total)
    assert is_integer(snapshot.blobs_bytes)
  end

  test "metrics_token is a key the parser, the environment check and the template all read" do
    assert {:ok, %{"metrics_token" => "s3cret"}} = Config.parse("metrics_token = s3cret")

    System.put_env("PDS_METRICS_TOKEN", "s3cret")
    on_exit(fn -> System.delete_env("PDS_METRICS_TOKEN") end)

    assert Config.validate_env() == :ok
    assert Config.template() =~ "# metrics_token ="
  end
end
