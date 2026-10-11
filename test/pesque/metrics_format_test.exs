defmodule Pesque.Metrics.FormatTest do
  @moduledoc """
  The exposition is a pure function of a snapshot, so it is tested as one:
  what it renders, that it escapes, and that the same snapshot always
  renders the same text.
  """

  use ExUnit.Case, async: true

  alias Pesque.Metrics.Format

  @base %{
    http_requests: %{{"/xrpc/com.atproto.server.getSession", 200} => 3},
    rate_limit_rejections: 2,
    firehose_commit_frames: 7,
    firehose_subscribers: 1,
    accounts: 4,
    blobs_total: 12,
    blobs_bytes: 3456
  }

  @session_line ~S(pesque_http_requests_total{route="/xrpc/com.atproto.server.getSession",status="200"} 3)

  test "every series carries its type line and its value" do
    text = Format.render(@base)

    assert text =~ ~s{# TYPE pesque_http_requests_total counter}
    assert text =~ @session_line

    assert text =~ ~s{# TYPE pesque_rate_limit_rejections_total counter}
    assert text =~ ~s{pesque_rate_limit_rejections_total 2}

    assert text =~ ~s{# TYPE pesque_firehose_commit_frames_total counter}
    assert text =~ ~s{pesque_firehose_commit_frames_total 7}

    assert text =~ ~s{# TYPE pesque_firehose_subscribers gauge}
    assert text =~ ~s{pesque_firehose_subscribers 1}

    assert text =~ ~s{# TYPE pesque_accounts_total gauge}
    assert text =~ ~s{pesque_accounts_total 4}

    assert text =~ ~s{# TYPE pesque_blobs_total gauge}
    assert text =~ ~s{pesque_blobs_total 12}

    assert text =~ ~s{# TYPE pesque_blobs_bytes gauge}
    assert text =~ ~s{pesque_blobs_bytes 3456}
  end

  test "a key the snapshot omits renders as zero, not as an absent series" do
    text = Format.render(%{})

    assert text =~ ~s{pesque_rate_limit_rejections_total 0}
    assert text =~ ~s{pesque_blobs_bytes 0}

    refute text =~ ~S(pesque_http_requests_total{)
  end

  test "the http samples are ordered by label, whatever order they arrived in" do
    snapshot = %{
      @base
      | http_requests: %{
          {"/xrpc/com.atproto.sync.getBlob", 200} => 9,
          {"/xrpc/com.atproto.server.createSession", 200} => 1,
          {"/metrics", 200} => 2
        }
    }

    text = Format.render(snapshot)
    lines = String.split(text, "\n")

    samples =
      for line <- lines, String.starts_with?(line, "pesque_http_requests_total{") do
        line
      end

    assert [
             ~S(pesque_http_requests_total{route="/metrics",status="200"} 2),
             ~S(pesque_http_requests_total{route="/xrpc/com.atproto.server.createSession",status="200"} 1),
             ~S(pesque_http_requests_total{route="/xrpc/com.atproto.sync.getBlob",status="200"} 9)
           ] == samples
  end

  test "label values are escaped the way the exposition format requires" do
    route = "route\\with\"quote\nnew"

    text = Format.render(%{@base | http_requests: %{{route, 200} => 1}})

    assert text =~
             ~S(pesque_http_requests_total{route="route\\with\"quote\nnew",status="200"} 1)
  end

  test "the same snapshot renders byte-for-byte the same text" do
    assert Format.render(@base) == Format.render(@base)
  end

  test "the body ends with a newline, as the exposition format requires" do
    assert String.ends_with?(Format.render(@base), "\n")
  end
end
