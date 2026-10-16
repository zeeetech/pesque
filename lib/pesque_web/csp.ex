defmodule PesqueWeb.Csp do
  @moduledoc """
  The content-security policies the server answers with.

  `strict/0` is the API surface: nothing loads, nothing frames. A page that
  links this origin's stylesheet, fonts and icon widens it to `pages/0`, and a
  page that posts a form widens it once more with `form-action 'self'`. None of
  them allows a script: the browser pages ship no JavaScript, so a script would
  have nothing legitimate to run.

  `form/1` widens the form policy with the origin the form's answer redirects
  to. A browser checks `form-action` against every hop a submission takes, so
  the consent form, which posts here and is answered with a redirect to the
  client, has to name the client's origin as well.
  """

  @strict "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"
  @pages @strict <> "; style-src 'self'; img-src 'self'; font-src 'self'"
  @form @pages <> "; form-action 'self'"

  @doc "The policy for the JSON and protocol surface."
  def strict, do: @strict

  @doc "The policy for a page: the landing, a handle page, an error page."
  def pages, do: @pages

  @doc "The policy for a page that posts a form: the consent page, signup."
  def form, do: @form

  @doc """
  The form policy for a page whose submission is answered with a redirect to
  `redirect_uri`: `form/0` plus that URI's origin, or, for a native app's
  private-use scheme, its scheme.

  The URI was checked against the client's metadata before the page was built,
  so this only reads it. A URI that names neither an origin nor a scheme leaves
  the policy at `form/0`.
  """
  def form(redirect_uri) when is_binary(redirect_uri) do
    case source(redirect_uri) do
      nil -> @form
      source -> @pages <> "; form-action 'self' " <> source
    end
  end

  defp source(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) ->
        port = if is_nil(port), do: "", else: ":#{port}"
        "#{scheme}://#{host}#{port}"

      # A native app's private-use scheme is written `scheme:/path` (RFC 8252,
      # one slash), so it carries a scheme and no host. The browser checks
      # `form-action` against the submission's redirect target, so the scheme
      # alone is the source that lets the consent form's answer reach the app.
      %URI{scheme: scheme} when is_binary(scheme) ->
        "#{scheme}:"

      _ ->
        nil
    end
  end
end
