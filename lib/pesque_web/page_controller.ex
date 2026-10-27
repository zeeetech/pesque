defmodule PesqueWeb.PageController do
  @moduledoc """
  The two pages a browser reaches by host: the landing at the server's own
  name, and one page per handle the server hosts.

  The host decides which. A name that is the server's own renders the landing;
  a name that resolves to an account renders that account's page; anything else
  is a 404. The consent page is not here: it belongs to the OAuth surface.
  """

  use Phoenix.Controller, formats: [:html]

  alias Pesque.Accounts
  alias Pesque.Identity
  alias PesqueWeb.Csp
  alias PesqueWeb.ErrorHTML
  alias PesqueWeb.Host
  alias PesqueWeb.Layout
  alias PesqueWeb.PageHTML

  def show(conn, _params) do
    cond do
      Host.server_host?(conn.host, [Pesque.hostname()]) -> render_landing(conn)
      match?({:ok, _did}, Accounts.resolve_handle(conn.host)) -> render_handle(conn)
      true -> ErrorHTML.not_found(conn)
    end
  end

  defp render_landing(conn) do
    assigns = %{
      hostname: Pesque.hostname(),
      mode: Pesque.mode(),
      handle_domain: Pesque.handle_domain(),
      registration: Pesque.registration(),
      version: Pesque.version(),
      account: single_account()
    }

    render_page(conn, PageHTML.landing(assigns), Pesque.hostname(), "/")
  end

  defp render_handle(conn) do
    {:ok, did} = Accounts.resolve_handle(conn.host)
    user = Accounts.get_user(did)

    assigns = %{
      handle: user.handle,
      did: user.did,
      active: user.active,
      home: Pesque.base_url()
    }

    render_page(conn, PageHTML.handle(assigns), user.handle, Pesque.base_url())
  end

  # Under single the server is the one account, so the landing also
  # carries its identity. There is no account until one is created, and a server
  # with none shows no identity rather than the DID it would mint.
  defp single_account do
    with :single <- Pesque.mode(),
         {:ok, did} <- Accounts.resolve_handle(Identity.handle()) do
      %{handle: Identity.handle(), did: did}
    else
      _none -> nil
    end
  end

  defp render_page(conn, body, title, home) do
    html =
      Layout.render(title, body,
        locale: conn.assigns.locale,
        locale_hrefs: conn.assigns.locale_hrefs,
        home: home,
        year: Date.utc_today().year
      )

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("content-security-policy", Csp.pages())
    |> put_resp_header("cache-control", "no-cache")
    |> html(html)
  end
end
