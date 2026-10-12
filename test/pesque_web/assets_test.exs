defmodule PesqueWeb.AssetsTest do
  @moduledoc """
  The static assets the pages need are actually reachable through the endpoint,
  which is the only place the static allowlist and the served paths are both in
  play.
  """

  use PesqueWeb.ConnCase, async: false

  defp request(path), do: dispatch(build_conn(), Endpoint, :get, path, nil)

  test "the stylesheet is served as css" do
    conn = request("/assets/zeetech.css")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/css"
  end

  test "the favicon and a font are served" do
    assert request("/assets/favicon.svg").status == 200
    assert request("/assets/fonts/ubuntu-300.woff2").status == 200
  end

  test "a file outside the allowlist is not served" do
    assert request("/mix.exs").status == 404
  end
end
