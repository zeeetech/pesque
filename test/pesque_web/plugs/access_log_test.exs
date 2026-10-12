defmodule PesqueWeb.Plugs.AccessLogTest do
  @moduledoc """
  What one access line carries.

  The point of the plug is that a line names its caller and, on a failure, says
  what the failure answered: without the requester an operator cannot tell a
  client's failed sign-in from an indexer's rejected read, and without the body
  the only way to learn why a request failed is to reproduce it. Both are
  asserted here, along with the fallback order the requester is read in.

  Sync, not async: the success line is `:info` and the test environment pins
  `Logger.level/0` to `:warning`, so the test has to lower it for the duration.
  A global level is not a thing to change under a running async test.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias PesqueWeb.Plugs.AccessLog

  describe "a successful response" do
    test "names the requester and logs no body" do
      conn =
        :get
        |> conn("/xrpc/com.atproto.repo.listRecords")
        |> put_req_header("user-agent", "Bluesky-Relay")

      log = capture_at(:info, fn -> respond(conn, 200, ~s({"records":[]})) end)

      assert log =~ "GET /xrpc/com.atproto.repo.listRecords 200 in "
      assert log =~ "requester=Bluesky-Relay"
      refute log =~ "body="
    end
  end

  describe "a failed response" do
    test "carries the body and the requester" do
      conn =
        :post
        |> conn("/oauth/token", %{"client_id" => "https://tangled.org/oauth/client-metadata.json"})
        |> put_req_header("user-agent", "Tangled")

      log =
        capture_log(fn ->
          respond(conn, 400, ~s({"error":"invalid_client","error_description":"nope"}))
        end)

      assert log =~ "POST /oauth/token 400 in "
      assert log =~ ~s(body={"error":"invalid_client")
      assert log =~ "requester=tangled.org"
    end

    test "names the authenticated account when no client is known" do
      conn =
        :post
        |> conn("/xrpc/com.atproto.repo.createRecord")
        |> assign(:did, "did:plc:alice")

      log = capture_log(fn -> respond(conn, 403, ~s({"error":"InsufficientScope"})) end)

      assert log =~ "requester=did:plc:alice"
    end

    test "falls back to the user agent when nothing else names the caller" do
      conn =
        :get
        |> conn("/xrpc/com.atproto.sync.getRepo")
        |> put_req_header("user-agent", "crawler/1.0")

      log = capture_log(fn -> respond(conn, 400, ~s({"error":"InvalidRequest"})) end)

      assert log =~ "requester=crawler/1.0"
    end

    test "reads the caller address from x-forwarded-for" do
      conn =
        :post
        |> conn("/oauth/token")
        |> put_req_header("x-forwarded-for", "203.0.113.7, 10.0.0.1")

      log = capture_log(fn -> respond(conn, 400, ~s({"error":"InvalidRequest"})) end)

      assert log =~ "remote_ip=203.0.113.7"
    end

    test "a server error is logged at the error level" do
      conn = conn(:get, "/xrpc/com.atproto.repo.listRecords")

      log =
        capture_log([level: :error], fn ->
          respond(conn, 500, ~s({"error":"InternalServerError"}))
        end)

      assert log =~ "500 in "
    end
  end

  defp respond(conn, status, body) do
    conn
    |> AccessLog.call([])
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # capture_log/2 cannot see a message below Logger.level/0, and the test
  # environment holds that at :warning. Lower it around the capture and put it
  # back, so an :info line can be asserted without the whole suite seeing a
  # different level.
  defp capture_at(level, fun) do
    previous = Logger.level()
    Logger.configure(level: level)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous)
    end
  end
end
