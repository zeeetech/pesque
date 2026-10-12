defmodule PesqueWeb.Layout do
  @moduledoc """
  The shell the browser pages share.

  Pure: a page is a body passed in, and this wraps it in the head, the symbol,
  the header and the footer. The symbol is inlined once and referenced by the
  header, so the mark costs no image request and the only image a page loads is
  the favicon.

  The locale switcher is two links, not a script: the page CSP allows no
  JavaScript, and a link carrying `locale` in the query is enough. The hrefs
  are built by the controller because they have to keep whatever query the page
  already carries, which the consent page does.
  """

  use Gettext, backend: PesqueWeb.Gettext

  import PesqueWeb.HTML, only: [escape: 1]

  # The brand symbol: the robot-head shield with the hidden Z, in the two
  # palette colors the directive names for a dark background.
  @symbol """
  <svg class="sprite" aria-hidden="true"><symbol id="zee" viewBox="0 0 83.15 78.82"><path fill="#9655ff" d="M0,41.92V1.98h17.12v5.62c2.31-1.62,4.82-2.99,7.53-4.1.53-.23,1.07-.44,1.6-.63,2.62-.99,5.39-1.71,8.27-2.17,2.26-.41,4.61-.65,7.06-.7,2.42.05,4.77.29,7.04.7,2.88.45,5.65,1.18,8.27,2.17.54.19,1.07.41,1.6.63,2.7,1.1,5.21,2.47,7.53,4.1V1.98h17.11v39.94l-.03,2.22v1.85c-.1,6.41-1.21,12.21-3.27,17.45-.49,1.25-1.02,2.44-1.62,3.59-2.01,4.01-4.6,7.51-7.77,10.56-.43.41-.87.81-1.32,1.2,3.94-6.32,6.26-14.06,6.26-22.41,0-21.35-14.71-35.73-33.39-35.73S7.75,35.03,7.75,56.38c0,8.37,2.33,16.12,6.29,22.44-.46-.4-.91-.81-1.36-1.23-3.16-3.04-5.75-6.54-7.76-10.56-.6-1.15-1.13-2.35-1.62-3.59C1.23,58.2.13,52.4.03,45.99c-.02-.34-.02-.68-.02-1.04l-.02-3.03Z"/><path fill="#fef5bc" d="M48.6,39.24l-28.29,29.93c-2.01-3.74-3.15-8.06-3.15-12.65,0-2.1.24-4.13.69-6.08h10.09v-11.19h20.67Z"/><path fill="#fef5bc" d="M66.54,56.52c0,1.69-.15,3.34-.45,4.94h-10.38v10.95h-21.79l28.6-30.06c2.55,4.07,4.03,8.93,4.03,14.16"/></symbol></svg>
  """

  @doc """
  Renders a page.

  `title` is the document title and `body` the page content. `opts` carries the
  locale, the switcher hrefs as `{locale, href}` pairs, the brand link target,
  the footer year and an optional meta description.
  """
  def render(title, body, opts) do
    locale = Keyword.fetch!(opts, :locale)
    hrefs = Keyword.fetch!(opts, :locale_hrefs)
    home = Keyword.fetch!(opts, :home)
    year = Keyword.fetch!(opts, :year)
    description = Keyword.get(opts, :description)

    """
    <!doctype html>
    <html lang="#{lang(locale)}">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="theme-color" content="#000a0f">
        <title>#{escape(title)}</title>
        #{description_tag(description)}
        <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
        <link rel="stylesheet" href="/assets/zeetech.css">
      </head>
      <body>
        #{@symbol}
        <a class="skip" href="#main">#{gettext("skip to content")}</a>
        <header class="top wrap">
          <a class="brand" href="#{escape(home)}">
            <svg><use href="#zee"/></svg>
            <b><i>/</i>zeetech</b>
          </a>
          #{switcher(locale, hrefs)}
        </header>
        <main id="main" class="wrap">
    #{body}
        </main>
        <footer>
          <div class="wrap">
            <div class="legal">
              <span class="k">zeetech</span> / zoey de souza pessanha consultoria em tecnologia da informação ltda<br>
              <span class="k">cnpj:</span> 51.907.268/0001-42 / <a href="mailto:zoey.spessanha@zeetech.io">zoey.spessanha@zeetech.io</a> / <a href="https://zeetech.io">zeetech.io</a>
            </div>
            <p class="copy">© #{year} zeetech / pesque v#{escape(Pesque.version())}</p>
          </div>
        </footer>
      </body>
    </html>
    """
  end

  # BCP 47 spells the region with a hyphen, gettext with an underscore.
  defp lang(locale), do: String.replace(locale, "_", "-")

  defp description_tag(nil), do: ""

  defp description_tag(text) do
    ~s(<meta name="description" content="#{escape(text)}">)
  end

  defp switcher(_locale, []), do: ""

  defp switcher(locale, hrefs) do
    links =
      Enum.map_join(hrefs, fn {name, href} ->
        current = if name == locale, do: "true", else: "false"
        ~s(<a href="#{escape(href)}" aria-current="#{current}">#{escape(short(name))}</a>)
      end)

    ~s(<nav class="locales" aria-label="#{escape(gettext("language"))}">#{links}</nav>)
  end

  defp short("pt_BR"), do: "pt"
  defp short("en"), do: "en"
  defp short(other), do: other
end
