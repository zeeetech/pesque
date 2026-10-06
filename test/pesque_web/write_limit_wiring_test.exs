defmodule PesqueWeb.WriteLimitWiringTest do
  @moduledoc """
  The account scope is a write scope, and deleteAccount is the expensive one on
  it. This pins the wiring rather than the plug: the bucket arithmetic is
  RateLimit's own test, and what regresses here is someone adding a route to the
  scope and forgetting that the scope is limited at all.
  """

  use PesqueWeb.ConnCase, async: false

  @account_routes [
    "/xrpc/com.atproto.server.requestAccountDelete",
    "/xrpc/com.atproto.server.deleteAccount",
    "/xrpc/com.atproto.server.deactivateAccount",
    "/xrpc/com.atproto.server.activateAccount",
    "/xrpc/com.atproto.identity.updateHandle",
    "/xrpc/com.atproto.server.createInviteCodes"
  ]

  @record_routes [
    "/xrpc/com.atproto.repo.createRecord",
    "/xrpc/com.atproto.repo.putRecord",
    "/xrpc/com.atproto.repo.deleteRecord",
    "/xrpc/com.atproto.repo.applyWrites",
    "/xrpc/com.atproto.repo.uploadBlob"
  ]

  test "every account and record write route answers the write budget" do
    for path <- @account_routes ++ @record_routes do
      conn = xrpc_post(path, %{}, nil)

      # 401 means the limit let the request through to the auth plug, which is
      # what a limited route does. 429 would mean the limiter refused it, which
      # for the first request of a window it never should.
      assert conn.status == 401, "#{path} answered #{conn.status}, expected the auth plug (401)"
      assert {"ratelimit-limit", "600"} in conn.resp_headers, "#{path} carries no write limit"
    end
  end

  # There is deliberately no test here that spends the budget down to a 429.
  #
  # The rate limit table is one process-wide ETS table, not per-test state, so
  # 601 requests from one test would leave the next test in the file, and every
  # async test running beside it, holding an exhausted write budget. That is
  # not a hypothetical: it turned 62 unrelated tests red across four modules,
  # and the count varied per run because it depended on which async tests
  # happened to overlap. The bucket arithmetic is already covered by
  # test/pesque/rate_limit_test.exs, where it is driven directly; what is worth
  # pinning here is the wiring, which the header assertion above does without
  # spending anything.
end
