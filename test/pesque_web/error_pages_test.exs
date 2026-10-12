defmodule PesqueWeb.ErrorPagesTest do
  @moduledoc """
  The error pages a browser gets, and the JSON an API client still gets for the
  same failure. The format is chosen from the accept header, so a browser and a
  client hitting the same path are answered differently on purpose.
  """

  use PesqueWeb.ConnCase, async: false

  defp request(path, opts \\ []) do
    conn =
      case opts[:accept] do
        nil -> build_conn()
        accept -> build_conn() |> put_req_header("accept", accept)
      end

    dispatch(conn, Endpoint, :get, path, nil)
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> hd()
  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> hd()

  test "a browser at an unknown path gets the error page" do
    conn = request("/nothing/here", accept: "text/html,application/xhtml+xml,*/*;q=0.8")

    assert conn.status == 404
    assert content_type(conn) =~ "text/html"
    assert conn.resp_body =~ "<!doctype html>"
    assert conn.resp_body =~ "não encontrado"
    assert conn.resp_body =~ "/assets/zeetech.css"
    refute conn.resp_body =~ "<script"
  end

  test "the error page is delivered as markup, not as escaped text" do
    conn = request("/nothing/here", accept: "text/html")

    refute conn.resp_body =~ "&lt;"
    refute conn.resp_body =~ "&gt;"
  end

  test "the error page gets the policy that lets it load the stylesheet" do
    conn = request("/nothing/here", accept: "text/html")

    assert csp(conn) =~ "style-src 'self'"
    assert csp(conn) =~ "font-src 'self'"
    refute csp(conn) =~ "unsafe-inline"
  end

  test "a client at the same path still gets the JSON error shape" do
    conn = request("/nothing/here", accept: "application/json")

    assert conn.status == 404
    assert content_type(conn) =~ "application/json"
    assert JSON.decode!(conn.resp_body)["error"] == "NotFound"
  end

  test "a request naming no format is treated as a client" do
    conn = request("/nothing/here")

    assert conn.status == 404
    assert content_type(conn) =~ "application/json"
  end

  test "the error page reads in the language the request asked for" do
    assert request("/nothing/here?locale=en", accept: "text/html").resp_body =~ "not found"
  end

  test "the error view answers every status with a page" do
    for {template, needle} <- [
          {"400.html", "requisição inválida"},
          {"401.html", "não autorizado"},
          {"403.html", "proibido"},
          {"404.html", "não encontrado"},
          {"500.html", "erro no servidor"},
          {"503.html", "erro no servidor"}
        ] do
      page = PesqueWeb.ErrorHTML.render(template, %{}) |> elem(1)

      assert page =~ "<!doctype html>", "#{template} did not render a document"
      assert page =~ needle, "#{template} did not render #{needle}"
      refute page =~ "class=\"locales\"", "#{template} carried a language switcher"
    end
  end
end
