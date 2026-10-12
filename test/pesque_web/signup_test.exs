defmodule PesqueWeb.SignupTest do
  @moduledoc """
  The signup form.

  A closed server hands accounts out by invite, so a test that creates one mints
  a code first. The page is reached by path rather than by host, so a request
  names no host of its own.
  """

  use PesqueWeb.ConnCase, async: false

  @password "hunter2hunter2"

  setup do
    %{code: invite_code()}
  end

  defp invite_code do
    {:ok, [%{codes: [code]}]} = Accounts.create_invite_codes(1, 1, [])
    code
  end

  defp get_page(path) do
    build_conn() |> dispatch(Endpoint, :get, path, nil)
  end

  # The signup bucket counts a request against the address it came from, and
  # every test would otherwise share the loopback's allowance for the hour the
  # suite runs in. An address of its own keeps a test to its own budget, which
  # is also the shape a request arrives in behind the proxy. The range is the
  # one reserved for documentation.
  defp post_form(params) do
    conn = build_conn() |> Map.put(:remote_ip, {203, 0, 113, unique_address()})
    dispatch(conn, Endpoint, :post, "/signup", params)
  end

  defp unique_address, do: :erlang.unique_integer([:positive]) |> rem(253) |> Kernel.+(1)

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> hd()
  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> hd()

  test "the form asks for the invite code on a closed server" do
    conn = get_page("/signup")

    assert conn.status == 200
    assert content_type(conn) =~ "text/html"
    assert conn.resp_body =~ "criar conta"
    assert conn.resp_body =~ "código do convite"
    assert conn.resp_body =~ "seu nome"
    assert conn.resp_body =~ "." <> Pesque.handle_domain()
    refute conn.resp_body =~ "<script"
  end

  test "a link that carries a code pre-fills it" do
    conn = get_page("/signup?code=ABCD1234")

    assert conn.resp_body =~ ~s(value="ABCD1234")
  end

  test "the page lets the form post to this origin and allows no script" do
    conn = get_page("/signup")

    assert csp(conn) =~ "form-action 'self'"
    refute csp(conn) =~ "unsafe-inline"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "a good code creates the account and lands on the confirmation", %{code: code} do
    conn = post_form(attrs(code, "bob", "bob@example.com"))

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert location =~ "/signup/done?handle=bob." <> Pesque.handle_domain()
    assert {:ok, _did} = Accounts.resolve_handle("bob." <> Pesque.handle_domain())
  end

  test "the confirmation names the account and shows no script", %{code: code} do
    post_form(attrs(code, "carol", "carol@example.com"))

    conn = get_page("/signup/done?handle=carol." <> Pesque.handle_domain())

    assert conn.status == 200
    assert conn.resp_body =~ "conta criada"
    assert conn.resp_body =~ "carol." <> Pesque.handle_domain()
    refute conn.resp_body =~ "<script"
  end

  test "a confirmation for a name nothing answers for goes back to the form" do
    conn = get_page("/signup/done?handle=nobody." <> Pesque.handle_domain())

    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/signup"]
  end

  test "a code is good for one account", %{code: code} do
    post_form(attrs(code, "dave", "dave@example.com"))

    conn = post_form(attrs(code, "erin", "erin@example.com"))

    assert conn.status == 200
    assert conn.resp_body =~ "Esse código não vale"
    assert {:error, :not_found} = Accounts.resolve_handle("erin." <> Pesque.handle_domain())
  end

  test "no code on a closed server is refused before anything is created" do
    conn =
      post_form(%{"handle" => "frank", "email" => "frank@example.com", "password" => @password})

    assert conn.status == 200
    assert conn.resp_body =~ "só com convite"
    assert {:error, :not_found} = Accounts.resolve_handle("frank." <> Pesque.handle_domain())
  end

  test "a code nothing names is refused" do
    conn = post_form(attrs("not-a-real-code", "gina", "gina@example.com"))

    assert conn.resp_body =~ "Esse código não vale"
  end

  test "a taken name comes back with what was typed still in the form" do
    alice = create_account("alice")
    label = alice.handle |> String.split(".") |> hd()

    conn = post_form(attrs(invite_code(), label, "new@example.com"))

    assert conn.status == 200
    assert conn.resp_body =~ "Esse nome já está em uso"
    assert conn.resp_body =~ ~s(value="#{label}")
    assert conn.resp_body =~ ~s(value="new@example.com")
  end

  test "a short password is refused" do
    conn =
      post_form(%{
        "invite_code" => invite_code(),
        "handle" => "hugo",
        "email" => "h@example.com",
        "password" => "short"
      })

    assert conn.resp_body =~ "pelo menos 8 caracteres"
  end

  test "a name with a dot is refused as a name" do
    conn = post_form(attrs(invite_code(), "i.j", "ij@example.com"))

    assert conn.resp_body =~ "Sem ponto"
  end

  test "the form reads in the language the request asked for" do
    conn = get_page("/signup?locale=en")

    assert conn.resp_body =~ "create account"
    assert conn.resp_body =~ "invite code"
  end

  test "the path is not served where the server is its single account" do
    put_mode(:conformant_single)

    assert get_page("/signup").status == 404
    assert post_form(%{"handle" => "x"}).status == 404
  end

  defp attrs(code, label, email) do
    %{"invite_code" => code, "handle" => label, "email" => email, "password" => @password}
  end
end
