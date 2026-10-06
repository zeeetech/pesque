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

  The page is plain HTML built here rather than through a view, because this
  project has no template layer and a login form does not need one. It is
  served with a CSP that permits exactly what it uses: a form posting to this
  origin, no script, no framing.

  The scope list is shown because the spec requires the approval prompt to
  identify the client and describe what was asked for, and the full client_id
  URL is shown because an untrusted client's `client_name` is a claim anybody
  can make.
  """

  use Phoenix.Controller, formats: [:html, :json]

  alias Pesque.Accounts
  alias Pesque.OAuth
  alias PesqueWeb.OAuth.Errors
  alias PesqueWeb.OAuth.Proof

  @doc "RFC 9126: the client pushes the request and gets a reference back."
  def par(conn, params) do
    with {:ok, checked} <- Proof.check(conn),
         {:ok, %{request_uri: request_uri, expires_in: expires_in}} <-
           OAuth.push_request(params, checked.assigns.dpop_jkt) do
      checked
      |> put_resp_header("cache-control", "no-store")
      |> Proof.with_nonce()
      |> json(%{"request_uri" => request_uri, "expires_in" => expires_in})
    else
      {:error, reason, failed} -> fail(failed, reason)
      {:error, reason} -> fail(conn, reason)
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
      {:error, reason} -> fail(conn, reason)
    end
  end

  def decide(conn, params) do
    with {:ok, request, request_uri} <-
           OAuth.fetch_request(params["request_uri"], params["client_id"]),
         {:ok, result} <- decide(params, request_uri, request, params) do
      redirect_to_client(conn, result)
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp decide(%{"decision" => "approve"}, request_uri, request, params) do
    with {:ok, user} <- login(params) do
      OAuth.approve(request_uri, request.client_id, user)
    end
  end

  defp decide(%{"decision" => "deny"}, request_uri, request, _params) do
    OAuth.deny(request_uri, request.client_id)
  end

  defp decide(_params, _request_uri, _request, _all), do: {:error, :invalid_credentials}

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

    conn |> no_store() |> redirect(external: location)
  end

  defp redirect_to_client(conn, %{error: error} = result) do
    location = append_query(result.redirect_uri, %{"error" => error, "state" => result.state})
    conn |> no_store() |> redirect(external: location)
  end

  defp append_query(uri, params), do: uri <> "?" <> URI.encode_query(params)

  # The response must never be cached: a cached login page would carry a
  # request_uri nobody may replay.
  defp render_page(conn, request, request_uri) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", page_csp())
    |> html(page(request, request_uri))
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  # default-src 'none' plus form-action 'self': the page loads nothing and posts
  # to this origin, and a login form that could post anywhere else is a
  # credential forward.
  defp page_csp,
    do: "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

  defp page(request, request_uri) do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Sign in to authorize</title>
      </head>
      <body>
        <main>
          <h1>Authorize #{escape(request.client_id)}</h1>
          <p>This application is asking to act as you with these scopes:</p>
          <ul>#{scopes_list(request.scope)}</ul>
          <form method="post" action="/oauth/authorize">
            <input type="hidden" name="client_id" value="#{escape(request.client_id)}">
            <input type="hidden" name="request_uri" value="#{escape(request_uri)}">
            <p>
              <label for="identifier">Handle or email</label>
              <input id="identifier" name="identifier" type="text" autocomplete="username"\
             value="#{escape(request.login_hint)}" required>
            </p>
            <p>
              <label for="password">Password</label>
              <input id="password" name="password" type="password"\
             autocomplete="current-password" required>
            </p>
            <p>
              <button type="submit" name="decision" value="approve">Authorize</button>
              <button type="submit" name="decision" value="deny">Cancel</button>
            </p>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp scopes_list(scope) do
    scope
    |> String.split(" ", trim: true)
    |> Enum.map_join("\n", fn scope -> "<li>#{escape(scope)}</li>" end)
  end

  # The client_id is attacker-chosen text rendered into a page, and so is the
  # login_hint the flow started with. Neither goes in unescaped.
  defp escape(nil), do: ""
  defp escape(value), do: value |> to_string() |> escape_html()

  defp escape_html(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp fail(conn, reason) do
    {status, code, description} = Errors.to_oauth(reason)

    conn
    |> no_store()
    |> put_status(status)
    |> json(%{"error" => code, "error_description" => description})
    |> halt()
  end
end
