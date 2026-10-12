defmodule PesqueWeb.Csp do
  @moduledoc """
  The content-security policies the browser pages answer with.

  The global policy in `PesqueWeb.Plugs.SecurityHeaders` is `default-src
  'none'`, which is right for the JSON surface and too strict for a page that
  links a stylesheet. A page that renders HTML replaces it with one of these,
  and neither allows a script: these pages ship no JavaScript, so a script
  would have nothing legitimate to run.
  """

  @pages "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; frame-ancestors 'none'"

  # The consent page is the one page that posts a form, and it posts to this
  # origin. Nothing else is added.
  @consent @pages <> "; form-action 'self'"

  @doc "The policy for the landing and the handle page."
  def pages, do: @pages

  @doc "The policy for the OAuth consent page."
  def consent, do: @consent
end
