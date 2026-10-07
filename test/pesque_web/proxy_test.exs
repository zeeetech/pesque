defmodule PesqueWeb.ProxyTest do
  @moduledoc """
  The proxy catch-all over real requests. The resolver and fetcher are
  injected, so no test reaches the network.
  """

  use PesqueWeb.ConnCase

  @target "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @endpoint "https://api.bsky.app"
  @request_id "0123456789abcdef0123456789abcdef"

  defmodule Directory do
    def resolve(did) do
      notify({:directory, did})
      :persistent_term.get(:proxy_web_test_document, {:error, :not_found})
    end

    defp notify(message) do
      case :persistent_term.get(:proxy_web_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  defmodule Fetch do
    def request(uri, method, headers, body, _opts) do
      notify({:fetch, uri, method, headers, body})

      :persistent_term.get(
        :proxy_web_test_response,
        {:ok, 200, [{"content-type", "application/json"}], "{}"}
      )
    end

    defp notify(message) do
      case :persistent_term.get(:proxy_web_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  setup do
    :persistent_term.put(:proxy_web_test_pid, self())
    :persistent_term.put(:proxy_web_test_document, {:ok, document()})
    Application.put_env(:pesque, :did_resolver_directory, Directory)
    Application.put_env(:pesque, :entryway_fetch, Fetch)

    on_exit(fn ->
      :persistent_term.erase(:proxy_web_test_pid)
      :persistent_term.erase(:proxy_web_test_document)
      :persistent_term.erase(:proxy_web_test_response)
      Application.delete_env(:pesque, :did_resolver_directory)
      Application.delete_env(:pesque, :entryway_fetch)
    end)

    %{user: create_account("proxy")}
  end

  test "an authenticated call with no proxy header is 501", %{user: user} do
    conn = request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, token(user), [])

    assert conn.status == 501

    assert JSON.decode!(conn.resp_body) == %{
             "error" => "MethodNotImplemented",
             "message" => "unknown XRPC method"
           }
  end

  test "a proxied call without a token is 401" do
    conn = request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, nil, [proxy_header()])

    assert conn.status == 401
  end

  test "a proxied call returns the upstream response", %{user: user} do
    :persistent_term.put(
      :proxy_web_test_response,
      {:ok, 200, [{"content-type", "application/json"}, {"x-secret", "nope"}], ~s({"ok":true})}
    )

    conn = request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, token(user), [proxy_header()])

    assert conn.status == 200
    assert conn.resp_body == ~s({"ok":true})
    assert get_resp_header(conn, "content-type") == ["application/json"]
    assert get_resp_header(conn, "x-secret") == []
  end

  test "an upstream error status is passed through", %{user: user} do
    :persistent_term.put(:proxy_web_test_response, {:ok, 404, [], ~s({"error":"NotFound"})})

    conn = request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, token(user), [proxy_header()])

    assert conn.status == 404
    assert conn.resp_body == ~s({"error":"NotFound"})
  end

  test "a target that does not resolve is 400", %{user: user} do
    :persistent_term.put(:proxy_web_test_document, {:error, :not_found})

    conn = request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, token(user), [proxy_header()])

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "a malformed proxy header is 400", %{user: user} do
    conn =
      request(:get, "/xrpc/app.bsky.feed.getTimeline", nil, token(user), [
        {"atproto-proxy", "not-a-did"}
      ])

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
  end

  test "the OPTIONS preflight advertises atproto-proxy" do
    conn = request(:options, "/xrpc/app.bsky.feed.getTimeline", nil, nil, [])

    [headers] = get_resp_header(conn, "access-control-allow-headers")
    assert headers =~ "atproto-proxy"
    assert headers =~ "atproto-accept-labelers"
  end

  # The official app sends headers this server does not know about
  # (`x-atproto-bsky-topics` today). Echoing what the browser asks for is what
  # keeps a new one from failing the preflight.
  test "the OPTIONS preflight echoes the headers the browser asks for" do
    conn =
      request(:options, "/xrpc/app.bsky.unspecced.getTrends", nil, nil, [
        {"access-control-request-headers", "x-atproto-bsky-topics, authorization"}
      ])

    [headers] = get_resp_header(conn, "access-control-allow-headers")
    assert headers =~ "x-atproto-bsky-topics"
    assert headers =~ "authorization"
  end

  defp request(method, path, body, token, headers) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> put_headers(headers)
    |> maybe_auth(token)
    |> dispatch(Endpoint, method, path, body)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp proxy_header, do: {"atproto-proxy", @target <> "#bsky_appview"}

  defp document do
    %{
      "id" => @target,
      "service" => [
        %{
          "id" => @target <> "#bsky_appview",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => @endpoint
        }
      ]
    }
  end
end
