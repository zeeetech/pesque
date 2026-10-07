defmodule PesqueWeb.PreferencesTest do
  @moduledoc """
  getPreferences / putPreferences over real requests: local, authenticated, and
  opaque.
  """

  use PesqueWeb.ConnCase

  @request_id "0123456789abcdef0123456789abcdef"
  @get "/xrpc/app.bsky.actor.getPreferences"
  @put "/xrpc/app.bsky.actor.putPreferences"

  setup do
    %{user: create_account("prefs")}
  end

  test "get with nothing stored answers an empty array", %{user: user} do
    conn = xrpc_get(@get, token(user))

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"preferences" => []}
  end

  test "put then get round-trips an unknown entry untouched", %{user: user} do
    preferences = [
      %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => false},
      %{"$type" => "com.example.unknown#thing", "whatever" => [1, 2, 3]}
    ]

    put = xrpc_post(@put, %{"preferences" => preferences}, token(user))
    assert put.status == 200
    assert JSON.decode!(put.resp_body) == %{}

    get = xrpc_get(@get, token(user))
    assert get.status == 200
    assert JSON.decode!(get.resp_body) == %{"preferences" => preferences}
  end

  test "a non-array body is 400", %{user: user} do
    conn = xrpc_post(@put, %{"preferences" => %{"not" => "a list"}}, token(user))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "both routes need a token" do
    assert xrpc_get(@get).status == 401
    assert xrpc_post(@put, %{"preferences" => []}, nil).status == 401
  end

  test "an over-cap array is 400", %{user: user} do
    big = %{"$type" => "com.example.big", "value" => String.duplicate("a", 1_048_577)}
    conn = xrpc_post(@put, %{"preferences" => [big]}, token(user))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "a proxy header on getPreferences is ignored", %{user: user} do
    conn =
      build_conn()
      |> put_req_header("x-request-id", @request_id)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> put_req_header("atproto-proxy", "did:plc:ewvi7nxzyoun6zhxrhs64oiz#bsky_appview")
      |> dispatch(Endpoint, :get, @get, nil)

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body) == %{"preferences" => []}
  end
end
