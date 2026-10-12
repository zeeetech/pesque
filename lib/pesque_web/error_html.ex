defmodule PesqueWeb.ErrorHTML do
  @moduledoc """
  The pages a browser is answered with when a request fails.

  Phoenix renders this view for a request that matched no route or raised,
  choosing it when the request accepts HTML and `PesqueWeb.ErrorJSON`
  otherwise, so the protocol surface keeps its error shape while a browser gets
  a page. The statuses are the ones the browser surface can reach: a request
  that could not be read, one without the sign-in it needed, one for a path
  nothing answers, and a server error.

  The locale is whatever the endpoint's locale plug resolved for the request,
  so an error reads in the same language as the page that failed. The shell
  carries no language switcher here: an error page has no meaningful target for
  one.
  """

  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  alias PesqueWeb.Layout

  @doc "Phoenix's error-view entry point, called with `\"<status>.html\"`."
  def render(template, _assigns), do: template |> status() |> page()

  defp status(template) do
    case Integer.parse(template) do
      {status, _rest} -> status
      :error -> 500
    end
  end

  defp page(status) do
    Layout.render(
      "#{status} #{title(status)}",
      body(status),
      locale: Gettext.get_locale(PesqueWeb.Gettext),
      locale_hrefs: [],
      home: "/",
      year: Date.utc_today().year
    )
  end

  defp body(status) do
    """
    <section class="hero">
      <p class="eyebrow">// #{status}</p>
      <h1>#{escape(title(status))}</h1>
      <p class="pitch">#{escape(detail(status))}</p>
      <div class="cta">
        <a class="btn" href="/">#{gettext("back to the start")}</a>
      </div>
    </section>
    """
  end

  defp title(400), do: gettext("bad request")
  defp title(401), do: gettext("unauthorized")
  defp title(403), do: gettext("forbidden")
  defp title(404), do: gettext("not found")
  defp title(_other), do: gettext("server error")

  defp detail(400), do: gettext("The request could not be read. Check the address and try again.")
  defp detail(401), do: gettext("This page needs a sign-in you did not provide.")
  defp detail(403), do: gettext("You are not allowed to see this.")
  defp detail(404), do: gettext("Nothing answers at this address.")

  defp detail(_other),
    do: gettext("Something went wrong on this server. The error has been logged.")
end
