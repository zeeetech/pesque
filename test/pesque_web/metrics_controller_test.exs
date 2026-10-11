defmodule PesqueWeb.MetricsControllerTest do
  @moduledoc """
  The gate: off is a 404, on is a bearer token, and the body is the
  exposition with a content type a scraper accepts.
  """

  use PesqueWeb.ConnCase, async: false

  alias PesqueWeb.Endpoint

  @endpoint Endpoint

  @token "a-long-random-metrics-token"

  setup do
    on_exit(fn -> Application.delete_env(:pesque, :metrics_token) end)
    :ok
  end

  test "with no token configured the route answers 404" do
    Application.delete_env(:pesque, :metrics_token)

    assert get(build_conn(), "/metrics").status == 404
  end

  test "with a token configured, a request without one answers 401" do
    Application.put_env(:pesque, :metrics_token, @token)

    assert get(build_conn(), "/metrics").status == 401
  end

  test "a wrong token answers 401 too" do
    Application.put_env(:pesque, :metrics_token, @token)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token <> "x")
      |> get("/metrics")

    assert conn.status == 401
  end

  test "the right token answers the exposition as text/plain" do
    Application.put_env(:pesque, :metrics_token, @token)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/metrics")

    assert conn.status == 200

    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/plain"

    assert conn.resp_body =~ "pesque_http_requests_total"
    assert conn.resp_body =~ "# TYPE pesque_accounts_total gauge"
  end
end
