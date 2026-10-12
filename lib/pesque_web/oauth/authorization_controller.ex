defmodule PesqueWeb.OAuth.AuthorizationController do
  @moduledoc """
  PAR and the authorize page.

  PAR is where the whole authorization request is validated, against the
  client's own published metadata, and turned into a `request_uri`. Nothing
  after it re-validates: the authorize endpoint reads a row.

  The authorize page is the account authentication the atproto profile requires
  inside the authorization flow. It reuses `Pesque.Accounts.verify_login/2`, so
  there is one credential store and one password hash per account, and the same
  argon2 work a session login does. A successful login here is not a session:
  it authorizes one request and grants nothing that outlives the code.

  The page is built here rather than through a view layer, like the rest of the
  browser surface: the shell is `PesqueWeb.Layout`, the body is the consent
  form, and the language is whatever `PesqueWeb.Plugs.SetLocale` resolved for
  the request, the same locale the permission sets are shown in. It is served
  with a CSP that permits the stylesheet, a form posting to this origin and the
  redirect to the client's origin it is answered with, and nothing else: no
  script, no framing.

  The scope list is shown because the spec requires the approval prompt to
  identify the client and describe what was asked for, and the full client_id
  URL is shown because an untrusted client's `client_name` is a claim anybody
  can make.
  """

  use Phoenix.Controller, formats: [:html, :json]
  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  alias Pesque.Accounts
  alias Pesque.OAuth
  alias Pesque.OAuth.Permission
  alias Pesque.OAuth.PermissionSets
  alias PesqueWeb.Csp
  alias PesqueWeb.Layout
  alias PesqueWeb.OAuth.Errors
  alias PesqueWeb.OAuth.Proof

  @doc "RFC 9126: the client pushes the request and gets a reference back."
  def par(conn, params) do
    with {:ok, checked} <- Proof.check(conn),
         {:ok, %{request_uri: request_uri, expires_in: expires_in}} <-
           OAuth.push_request(params, checked.assigns.dpop_jkt) do
      checked
      |> Errors.no_store()
      |> Proof.with_nonce()
      |> json(%{"request_uri" => request_uri, "expires_in" => expires_in})
    else
      {:error, reason, failed} -> Errors.render(failed, reason)
      {:error, reason} -> Errors.render(conn, reason)
    end
  end

  @doc """
  The authorization interface.

  GET shows the login form for a pushed request. POST takes the credentials and
  a decision: approve mints a code and redirects, deny redirects back with
  `access_denied`.

  Only `client_id` and `request_uri` are read here. A request carrying
  `response_type`, `redirect_uri`, `scope` or `code_challenge` in the query has
  not been pushed, and is refused rather than honoured, which is what the
  `require_pushed_authorization_requests` flag in the metadata promises.
  """
  def authorize(conn, params) do
    with {:ok, request, request_uri} <-
           OAuth.fetch_request(params["request_uri"], params["client_id"]) do
      render_page(conn, request, request_uri)
    else
      {:error, reason} -> Errors.render(conn, reason)
    end
  end

  def decide(conn, params) do
    with {:ok, request, request_uri} <-
           OAuth.fetch_request(params["request_uri"], params["client_id"]),
         {:ok, result} <- decide(params, request_uri, request) do
      redirect_to_client(conn, result)
    else
      {:error, reason} -> Errors.render(conn, reason)
    end
  end

  defp decide(%{"decision" => "approve"} = params, request_uri, request) do
    with {:ok, user} <- login(params) do
      OAuth.approve(request_uri, request.client_id, user, checked_scopes(params))
    end
  end

  defp decide(%{"decision" => "deny"}, request_uri, request) do
    OAuth.deny(request_uri, request.client_id)
  end

  defp decide(_params, _request_uri, _request), do: {:error, :invalid_credentials}

  # The checkbox values the consent page posted. One value arrives as a bare
  # binary, several as a list, and none at all means the account holder
  # unticked everything.
  defp checked_scopes(%{"scopes" => scopes}), do: List.wrap(scopes)
  defp checked_scopes(_params), do: []

  defp login(%{"identifier" => identifier, "password" => password}) do
    case Accounts.verify_login(identifier, password) do
      {:ok, user} -> {:ok, user}
      :error -> {:error, :invalid_credentials}
    end
  end

  # The approval redirect carries iss alongside code and state, because the
  # metadata says this server supports it and a client uses it to confirm that
  # the server which answered is the one it started with.
  defp redirect_to_client(conn, %{code: code} = result) do
    location =
      append_query(result.redirect_uri, %{
        "code" => code,
        "state" => result.state,
        "iss" => result.issuer
      })

    conn |> Errors.no_store() |> redirect(external: location)
  end

  defp redirect_to_client(conn, %{error: error} = result) do
    location = append_query(result.redirect_uri, %{"error" => error, "state" => result.state})
    conn |> Errors.no_store() |> redirect(external: location)
  end

  defp append_query(uri, params), do: uri <> "?" <> URI.encode_query(params)

  # The response must never be cached: a cached login page would carry a
  # request_uri nobody may replay.
  defp render_page(conn, request, request_uri) do
    html =
      Layout.render(
        gettext("sign in to authorize"),
        page(request, request_uri, conn.assigns.lang),
        locale: conn.assigns.locale,
        locale_hrefs: conn.assigns.locale_hrefs,
        home: "/",
        year: Date.utc_today().year
      )

    conn
    |> put_resp_content_type("text/html")
    |> Errors.no_store()
    |> put_resp_header("content-security-policy", Csp.form(request.redirect_uri))
    |> html(html)
  end

  # The scope list is the consent itself: atproto is always granted and is
  # shown as the fixed line the profile describes it by, and every other
  # requested scope is one pre-ticked checkbox the account holder can untick,
  # named by the sentence the permission grammar writes for it. An include:
  # names a permission set, so its label is the set's own title and detail and
  # its expansion is one click away; the checkbox narrows all of it or none.
  defp page(request, request_uri, lang) do
    """
    <section class="hero">
      <p class="eyebrow">// oauth</p>
      <h1>#{gettext("authorize")}</h1>
      <p class="pitch">#{gettext("This application is asking to act as you with these scopes:")}</p>
      <p class="client">#{escape(request.client_id)}</p>
    </section>
    <form class="consent" method="post" action="/oauth/authorize">
      <ul class="scopes">#{scope_items(request.scope, lang)}</ul>
      <input type="hidden" name="client_id" value="#{escape(request.client_id)}">
      <input type="hidden" name="request_uri" value="#{escape(request_uri)}">
      <div class="field">
        <label for="identifier">#{gettext("Handle or email")}</label>
        <input id="identifier" name="identifier" type="text" autocomplete="username" value="#{escape(request.login_hint)}" required>
      </div>
      <div class="field">
        <label for="password">#{gettext("Password")}</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
      </div>
      <div class="actions">
        <button class="btn primary" type="submit" name="decision" value="approve">#{gettext("Authorize")}</button>
        <button class="btn" type="submit" name="decision" value="deny">#{gettext("Cancel")}</button>
      </div>
    </form>
    """
  end

  defp scope_items(scope, lang) do
    scope
    |> String.split(" ", trim: true)
    |> Enum.uniq()
    |> Enum.map_join("\n", &scope_item(&1, lang))
  end

  defp scope_item(scope, lang) do
    case Permission.parse_scope(scope) do
      {:ok, %Permission{resource: :atproto} = permission} ->
        "<li>#{escape(Permission.describe(permission))}</li>"

      {:ok, %Permission{resource: :include} = permission} ->
        include_item(permission, lang)

      {:ok, permission} ->
        checkbox(permission, escape(Permission.describe(permission)))

      # A request on this page was validated at PAR, so this reads only as
      # what it is: a scope string this build could not describe.
      {:error, _reason} ->
        "<li>#{escape(scope)}</li>"
    end
  end

  defp include_item(permission, lang) do
    case PermissionSets.resolve(permission.nsid) do
      {:ok, document} ->
        include_block(permission, PermissionSets.set_display(document, lang), document)

      # PAR already resolved this set, so the page is only ever here while
      # the answer changed under the request; the include's own sentence is
      # what such a page falls back to.
      {:error, _reason} ->
        checkbox(permission, escape(Permission.describe(permission)))
    end
  end

  # The set's own title is the checkbox label, its detail sits under it, and
  # the granular permissions it expands to are folded away until asked for:
  # the specification wants them visible without making every consent page
  # scroll for a page and a half. The label carries only the checkbox and its
  # text; a details block inside one would make opening it tick the box.
  defp include_block(permission, display, document) do
    items =
      permission
      |> PermissionSets.expand(document)
      |> Enum.map(&Permission.describe/1)
      |> Enum.map_join("\n", &"<li>#{escape(&1)}</li>")

    value = escape(Permission.serialize(permission))

    "<li><label><input type=\"checkbox\" name=\"scopes\" value=\"#{value}\" checked> " <>
      "#{escape(display.title)}</label>" <>
      "<p>#{escape(display.detail)}</p>" <>
      "<details><summary>#{gettext("What this set grants")}</summary><ul>#{items}</ul></details>" <>
      "<p>#{escape(Permission.describe(permission))}</p></li>"
  end

  defp checkbox(permission, label_html) do
    value = escape(Permission.serialize(permission))

    "<li><label><input type=\"checkbox\" name=\"scopes\" value=\"#{value}\" checked> " <>
      "#{label_html}</label></li>"
  end
end
