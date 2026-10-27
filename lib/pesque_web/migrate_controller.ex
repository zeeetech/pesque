defmodule PesqueWeb.MigrateController do
  @moduledoc """
  The move form: how an account that lives on another atproto server comes to
  live on this one.

  The form asks where the account is now, what its name, its email and its
  password are, and hands them to `Pesque.Migrate.Runner.start/2`, which runs
  the move off-request. What a person holds is the move's token, so a
  submitted form is answered with the page that watches it, and the code the
  old server emails is handed in on that same page.

  The path exists only under `multi`, like signup: under
  `single` the server is its single account, so there is nothing
  here to serve and the path answers 404.

  A failure the form can answer comes back as the form with what was typed
  still in it and a sentence saying what to do next. Once the move is open,
  the row is the story: `Pesque.Migrate.Jobs` carries the phase, and the
  failures the move lands there are codes this page has a sentence for.
  """

  use Phoenix.Controller, formats: [:html]
  use Gettext, backend: PesqueWeb.Gettext

  import Plug.Conn

  require Logger

  alias Pesque.Migrate.Jobs
  alias Pesque.Migrate.Runner
  alias PesqueWeb.Csp
  alias PesqueWeb.ErrorHTML
  alias PesqueWeb.Layout
  alias PesqueWeb.MigrateHTML

  # The path is for a server with many accounts. Under single the
  # account already exists, made by its operator, so there is no form here and
  # the path reads like any other this server does not have.
  plug :require_multi

  # A move that is still going has a page that watches the row, and the row is
  # all the page has: the tag below re-reads it every three seconds until the
  # phase changes. A page someone is typing the code into must not reload, so
  # it is only on the :running one.
  @refresh ~s(<meta http-equiv="refresh" content="3">)

  @doc "The form, with the invite code pre-filled when the link carried one."
  def show(conn, params) do
    render_form(conn, %{
      invite_code: params["code"],
      old_pds: nil,
      handle: nil,
      email: nil,
      error: nil
    })
  end

  @doc "Opens the move, starts it, and answers with the page that watches it."
  def create(conn, params) do
    with {:ok, old_pds} <- old_pds(params),
         {:ok, handle} <- handle(params),
         {:ok, email} <- email(params),
         {:ok, password} <- password(params),
         {:ok, invite} <- invite_opts(params),
         {:ok, job} <- Jobs.open(handle, old_pds) do
      opts = [old_pds: old_pds, handle: handle, email: email, password: password] ++ invite
      Runner.start(job, opts)

      redirect(conn, to: "/migrate/" <> job.token)
    else
      {:error, reason} -> render_failure(conn, params, reason)
    end
  end

  @doc "The page that watches a move, or the not-found page for a nameless token."
  def status(conn, params) do
    case Jobs.get(params["token"]) do
      nil ->
        ErrorHTML.not_found(conn)

      job ->
        head = if job.phase == :running, do: @refresh, else: nil
        render_status(conn, job, head)
    end
  end

  @doc """
  Hands the code from the email to the move, and answers with the page again.

  The answer is a redirect, so a reload does not submit the code a second
  time. A move that has moved on does not take the code, and the page it
  answers with tells the story the row already carries.
  """
  def submit_code(conn, params) do
    case Runner.submit_code(params["token"], params["code"]) do
      :ok ->
        redirect(conn, to: "/migrate/" <> params["token"])

      {:error, :not_running} ->
        case Jobs.get(params["token"]) do
          nil ->
            ErrorHTML.not_found(conn)

          # A move still waiting on a code with nothing registered is one
          # whose code went unanswered, so its story is the code taking too
          # long. Every other phase already tells its own story, so the row
          # renders as it is.
          %{phase: :awaiting_code} = job ->
            render_status(conn, %{job | phase: :failed, error: "code_timeout"}, nil)

          job ->
            render_status(conn, job, nil)
        end
    end
  end

  defp require_multi(conn, _opts) do
    if Pesque.mode() == :multi do
      conn
    else
      conn |> ErrorHTML.not_found() |> halt()
    end
  end

  # Exactly signup's rule: a closed server asks for a code, an open one does
  # not, and a code that came is trimmed once here. The move claims the code
  # when it creates the account, which is a step the move can fail at, so the
  # code is the person's to fix either way.
  defp invite_opts(%{"invite_code" => code}) when is_binary(code) and code != "" do
    {:ok, [invite_code: String.trim(code)]}
  end

  defp invite_opts(_params) do
    case Pesque.registration() do
      :open -> {:ok, []}
      :closed -> {:error, :invite_code_required}
    end
  end

  # The old server is a URL the person names, so it is trimmed once here and
  # everything downstream reads the trimmed form. Only https: the move sends
  # the account's password to this address, so a cleartext one is refused
  # before anything runs.
  defp old_pds(%{"old_pds" => pds}) when is_binary(pds) do
    pds = String.trim(pds)

    if String.starts_with?(pds, "https://") do
      {:ok, pds}
    else
      {:error, :invalid_old_pds}
    end
  end

  defp old_pds(_params), do: {:error, :invalid_old_pds}

  # The name is the full handle, not the label signup asks for: a move can
  # bring a name no domain of this server is under, so nothing is appended
  # here. A name with whitespace in it is not a name, and a name without a
  # dot is a label, not a handle.
  defp handle(%{"handle" => handle}) when is_binary(handle) do
    handle = String.trim(handle)

    cond do
      handle == "" -> {:error, :invalid_handle}
      handle =~ ~r/\s/ -> {:error, :invalid_handle}
      not String.contains?(handle, ".") -> {:error, :invalid_handle}
      true -> {:ok, handle}
    end
  end

  defp handle(_params), do: {:error, :invalid_handle}

  defp email(%{"email" => email}) when is_binary(email) and email != "", do: {:ok, email}
  defp email(_params), do: {:error, :email_required}

  defp password(%{"password" => password}) when is_binary(password) and password != "",
    do: {:ok, password}

  defp password(_params), do: {:error, :password_required}

  # What was typed, minus the password: the form carries it back so a rejected
  # form does not make the person type it again.
  defp typed(params, reason) do
    %{
      invite_code: params["invite_code"],
      old_pds: params["old_pds"],
      handle: params["handle"],
      email: params["email"],
      error: reason
    }
  end

  # A reason the page has a sentence for is the person's to fix and needs no
  # log. One it does not is this server's own failure, and a sentence a person
  # cannot act on is worth a line an operator can: without this the reason
  # only ever reaches the page as "something went wrong".
  defp render_failure(conn, params, reason) do
    unless MigrateHTML.named?(reason) do
      Logger.warning("migration failed", reason: inspect(reason))
    end

    render_form(conn, typed(params, reason))
  end

  defp render_form(conn, assigns) do
    assigns =
      Map.merge(assigns, %{
        registration: Pesque.registration(),
        handle_domain: Pesque.handle_domain()
      })

    render_page(conn, MigrateHTML.form(assigns), gettext("move your account"))
  end

  defp render_status(conn, job, head) do
    body = MigrateHTML.status(%{job: job, handle_domain: Pesque.handle_domain()})

    render_page(conn, body, gettext("the move"), head)
  end

  # No store, because the form carries an invite code and a cached page would
  # hand it to the next person at the browser.
  defp render_page(conn, body, title, head \\ nil) do
    html =
      Layout.render(title, body,
        locale: conn.assigns.locale,
        locale_hrefs: conn.assigns.locale_hrefs,
        home: "/",
        year: Date.utc_today().year,
        head: head
      )

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("content-security-policy", Csp.form())
    |> put_resp_header("cache-control", "no-store")
    |> html(html)
  end
end
