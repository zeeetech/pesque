defmodule PesqueWeb.Csp do
  @moduledoc """
  The content-security policies the server answers with.

  `strict/0` is the API surface: nothing loads, nothing frames. A page that
  links this origin's stylesheet, fonts and icon widens it to `pages/0`, and
  the consent page, the one page that posts a form, widens it once more with
  `form-action 'self'`. None of them allows a script: the browser pages ship no
  JavaScript, so a script would have nothing legitimate to run.
  """

  @strict "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"
  @pages @strict <> "; style-src 'self'; img-src 'self'; font-src 'self'"
  @consent @pages <> "; form-action 'self'"

  @doc "The policy for the JSON and protocol surface."
  def strict, do: @strict

  @doc "The policy for the landing, the handle page and the error pages."
  def pages, do: @pages

  @doc "The policy for the OAuth consent page."
  def consent, do: @consent
end
