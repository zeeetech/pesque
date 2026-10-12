defmodule PesqueWeb.ConsentPageTest do
  @moduledoc """
  The consent page's shell, its policy and its language, over a real pushed
  request. The flow itself is covered elsewhere; this is about what the page a
  person is asked to trust looks like and what it is allowed to load.
  """

  use PesqueWeb.ConnCase, async: false

  alias PesqueWeb.OAuthCase, as: Client

  setup do
    %{key: Client.dpop_key()}
  end

  defp consent(key, lang \\ nil) do
    pushed = Client.par(key)
    Client.authorize_page(pushed.request_uri, pushed.params["client_id"], lang)
  end

  test "the consent page renders the shared shell and no script", %{key: key} do
    conn = consent(key)

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/html"
    assert conn.resp_body =~ "/assets/zeetech.css"
    refute conn.resp_body =~ "<script"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "the consent policy allows the form and the stylesheet, and no script", %{key: key} do
    csp = consent(key) |> get_resp_header("content-security-policy") |> hd()

    assert csp =~ "form-action 'self'"
    assert csp =~ "style-src 'self'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "unsafe-eval"
  end

  test "the consent page defaults to Portuguese", %{key: key} do
    body = consent(key).resp_body

    assert body =~ "Autorizar"
    assert body =~ "Senha"
  end

  test "the consent page answers in English when the browser asks", %{key: key} do
    body = consent(key, "en").resp_body

    assert body =~ "Authorize"
    assert body =~ "Password"
  end
end
