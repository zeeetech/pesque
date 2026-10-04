defmodule PesqueWeb.HealthTest do
  @moduledoc """
  The health check is what a container orchestrator or an uptime probe calls,
  so it has to mean something beyond "a process answered".
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias PesqueWeb.Endpoint

  @endpoint Endpoint

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "reports the database as reachable" do
    conn = get(build_conn(), "/xrpc/_health")

    assert conn.status == 200

    assert %{"status" => "ok", "version" => _version, "checks" => %{"database" => "ok"}} =
             JSON.decode!(conn.resp_body)
  end
end
