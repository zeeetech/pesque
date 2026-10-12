defmodule PesqueWeb.SignupController do
  @moduledoc """
  The signup form: how a person without an account gets one on a server whose
  registration is closed.

  An operator hands out the invite code from `pesque invite create`, so the
  code is the whole gate. The form asks for the code, the name the person
  wants, an email and a password, and hands them to
  `Pesque.Accounts.create_account/4`, which mints the identity and writes the
  account in one step. Nothing here signs the person in: the browser surface
  has no session, and the account is used through a client.

  The path exists only under `path_multi`, where an account is one of many.
  Under `conformant_single` the server is its single account, created by its
  operator, so there is nothing here to serve and the path answers 404.

  A failure the domain answers comes back as the form with what was typed still
  in it and a sentence saying what to do next. The success is a redirect to a
  confirmation, so a reload does not submit the form a second time.
  """

  use Phoenix.Controller, formats: [:html]
  use Gettext, backend: PesqueWeb.Gettext

  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Did
  alias PesqueWeb.Csp
  alias PesqueWeb.ErrorHTML
  alias PesqueWeb.Layout
  alias PesqueWeb.SignupHTML

  # The path is for a server with many accounts. Under conformant_single there
  # is no form here, and the path reads like any other this server does not
  # have rather than as a form that could never succeed.
  plug :require_path_multi

  @doc "The form, with the invite code pre-filled when the link carried one."
  def show(conn, params) do
    render_form(conn, %{invite_code: params["code"], handle: nil, email: nil, error: nil})
  end

  @doc "Creates the account, or shows the form again with what went wrong."
  def create(conn, params) do
    with {:ok, opts} <- invite_opts(params),
         {:ok, handle} <- handle(params) do
      case Accounts.create_account(handle, params["email"], params["password"], opts) do
        {:ok, user} ->
          redirect(conn, to: "/signup/done?" <> URI.encode_query(%{"handle" => user.handle}))

        {:error, reason} ->
          render_form(conn, typed(params, reason))
      end
    else
      {:error, reason} -> render_form(conn, typed(params, reason))
    end
  end

  @doc """
  The confirmation a created account is redirected to.

  It is a GET so a reload is harmless, and it only renders for a name that
  resolves: a handle nothing answers for is not an account this server made.
  """
  def done(conn, %{"handle" => handle}) do
    case Accounts.resolve_handle(handle) do
      {:ok, did} -> render_done(conn, Accounts.get_user(did))
      {:error, _reason} -> redirect(conn, to: "/signup")
    end
  end

  def done(conn, _params), do: redirect(conn, to: "/signup")

  defp require_path_multi(conn, _opts) do
    if Pesque.mode() == :path_multi do
      conn
    else
      conn |> ErrorHTML.not_found() |> halt()
    end
  end

  # The code the operator minted. An open registration asks for none, and the
  # form is rendered without the field for it.
  defp invite_opts(%{"invite_code" => code}) when is_binary(code) and code != "" do
    {:ok, [invite_code: String.trim(code)]}
  end

  defp invite_opts(_params) do
    case Pesque.registration() do
      :open -> {:ok, []}
      :closed -> {:error, :invite_code_required}
    end
  end

  # The form takes the label, not the whole handle: the domain is the server's
  # and is shown beside the field, so a person types the one part that is
  # theirs. The label is normalized by the same function the domain uses, so
  # the two cannot disagree about what a name may be.
  defp handle(%{"handle" => label}) when is_binary(label) do
    case Did.normalize_username(label) do
      {:ok, username} -> {:ok, username <> "." <> Pesque.handle_domain()}
      {:error, _reason} -> {:error, :invalid_handle}
    end
  end

  defp handle(_params), do: {:error, :invalid_handle}

  defp typed(params, reason) do
    %{
      invite_code: params["invite_code"],
      handle: params["handle"],
      email: params["email"],
      error: reason
    }
  end

  defp render_form(conn, assigns) do
    assigns =
      Map.merge(assigns, %{
        registration: Pesque.registration(),
        handle_domain: Pesque.handle_domain()
      })

    render_page(conn, SignupHTML.form(assigns), gettext("create account"))
  end

  defp render_done(conn, user) do
    render_page(conn, SignupHTML.done(%{handle: user.handle}), gettext("account created"))
  end

  # No store, because the form carries an invite code and a cached page would
  # hand it to the next person at the browser.
  defp render_page(conn, body, title) do
    html =
      Layout.render(title, body,
        locale: conn.assigns.locale,
        locale_hrefs: conn.assigns.locale_hrefs,
        home: "/",
        year: Date.utc_today().year
      )

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("content-security-policy", Csp.form())
    |> put_resp_header("cache-control", "no-store")
    |> html(html)
  end
end
