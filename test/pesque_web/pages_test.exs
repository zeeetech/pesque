defmodule PesqueWeb.PagesTest do
  @moduledoc """
  The two pages a browser reaches by host.

  ConnTest because the host on the wire decides which page a request lands on,
  and only the endpoint sees it. A request goes out with an explicit host, the
  way a real one arrives.
  """

  use PesqueWeb.ConnCase, async: false

  setup do
    %{alice: create_account("alice")}
  end

  defp request(path, host) do
    build_conn()
    |> Map.put(:host, host)
    |> dispatch(Endpoint, :get, path, nil)
  end

  defp content_type(conn) do
    conn |> get_resp_header("content-type") |> hd()
  end

  defp csp(conn) do
    conn |> get_resp_header("content-security-policy") |> hd()
  end

  test "the server's own name renders the landing" do
    conn = request("/", Pesque.hostname())

    assert conn.status == 200
    assert content_type(conn) =~ "text/html"
    assert conn.resp_body =~ Pesque.hostname()
    assert conn.resp_body =~ "pesque v" <> Pesque.version()
    refute conn.resp_body =~ "<script"
  end

  test "the landing reflects the configuration" do
    conn = request("/", Pesque.hostname())

    assert conn.resp_body =~ Pesque.handle_domain()
    assert conn.resp_body =~ "servidor comunitário"
    assert conn.resp_body =~ "só com convite"
  end

  test "the landing allows the stylesheet and no script" do
    conn = request("/", Pesque.hostname())

    assert csp(conn) =~ "style-src 'self'"
    assert csp(conn) =~ "font-src 'self'"
    refute csp(conn) =~ "unsafe-inline"
    refute csp(conn) =~ "unsafe-eval"
  end

  test "the landing is not cached" do
    conn = request("/", Pesque.hostname())

    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "the locale query switches the language and leaves a cookie" do
    conn = request("/?locale=en", Pesque.hostname())

    assert conn.resp_body =~ "this server"
    assert conn.resp_body =~ "community server"
    assert conn |> get_resp_header("set-cookie") |> hd() =~ "locale=en"
  end

  test "the browser's language is honored when nothing else chose" do
    conn =
      build_conn()
      |> Map.put(:host, Pesque.hostname())
      |> put_req_header("accept-language", "en-US,en;q=0.9")
      |> dispatch(Endpoint, :get, "/", nil)

    assert conn.resp_body =~ "this server"
  end

  test "a hosted handle renders its own page", %{alice: alice} do
    conn = request("/", alice.handle)

    assert conn.status == 200
    assert conn.resp_body =~ alice.handle
    assert conn.resp_body =~ alice.did
    assert conn.resp_body =~ "https://bsky.app/profile/" <> alice.handle
  end

  test "a handle page never shows the account's email", %{alice: alice} do
    conn = request("/", alice.handle)

    refute conn.resp_body =~ alice.email
  end

  test "a deactivated account keeps its page and says it is dormant", %{alice: alice} do
    assert {:ok, _user} = Accounts.deactivate_account(alice)

    conn = request("/", alice.handle)

    assert conn.status == 200
    assert conn.resp_body =~ "inativa"
  end

  test "a name that is neither the server nor a handle is a 404" do
    conn = request("/", "nobody.localhost")

    assert conn.status == 404
  end
end
