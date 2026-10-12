defmodule PesqueWeb.HandleAvailabilityTest do
  @moduledoc """
  com.atproto.temp.checkHandleAvailability: the signup helper.
  """

  use PesqueWeb.ConnCase, async: false

  @path "/xrpc/com.atproto.temp.checkHandleAvailability"

  test "a free handle is available and needs no token" do
    handle = unique("free") <> ".localhost"
    body = read(handle)

    assert body["handle"] == handle
    assert body["result"]["$type"] == "com.atproto.temp.checkHandleAvailability#resultAvailable"
  end

  test "a taken handle is unavailable and suggests free ones" do
    alice = create_account("alice")
    body = read(alice.handle)

    assert body["result"]["$type"] ==
             "com.atproto.temp.checkHandleAvailability#resultUnavailable"

    assert [%{"handle" => _, "method" => _} | _] = body["result"]["suggestions"]
  end

  test "the email's local part is used to build a suggestion" do
    alice = create_account("alice")
    body = read(alice.handle, "&email=coolname@example.com")

    suggestions = body["result"]["suggestions"]
    assert %{"handle" => "coolname.localhost", "method" => "email"} in suggestions
  end

  test "needs a handle" do
    conn = xrpc_get(@path)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  defp read(handle, extra \\ "") do
    conn = xrpc_get(@path <> "?handle=" <> enc(handle) <> extra)

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
