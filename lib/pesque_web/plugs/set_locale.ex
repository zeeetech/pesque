defmodule PesqueWeb.Plugs.SetLocale do
  @moduledoc """
  Resolves the language for a browser request and stores it for gettext.

  Order: the `locale` query parameter, then the cookie it leaves behind, then
  the first language the browser asked for, then the default. Only a locale
  this build ships is accepted, so a header or a tampered cookie cannot pick
  one that does not exist.

  A `locale` in the query is remembered in a cookie, which is how the switcher
  works without a script: the link carries the choice, the response renders in
  it, and the next request reads the cookie. The query wins over the cookie so
  a switch takes effect on the request that carries it.

  Two values come out. `:locale` is the shipped locale gettext renders with.
  `:lang` is the tag a permission set is offered, and it is a different
  question: a set matches the request's primary tag exactly, so a browser's own
  `en-GB` is offered as `en-GB`, not normalized to the shipped `en`, and only an
  explicit choice is offered as the locale it selected.
  """

  import Plug.Conn

  alias PesqueWeb.Gettext, as: Backend

  @cookie "locale"
  @max_age 60 * 60 * 24 * 365

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    requested = conn.query_params["locale"]
    locale = resolve(conn, requested)

    Gettext.put_locale(Backend, locale)

    conn
    |> assign(:locale, locale)
    |> assign(:lang, set_lang(conn, requested))
    |> assign(:locale_hrefs, locale_hrefs(conn))
    |> remember(requested, locale)
  end

  defp remember(conn, nil, _locale), do: conn

  defp remember(conn, _requested, locale) do
    put_resp_cookie(conn, @cookie, locale, max_age: @max_age, same_site: "Lax")
  end

  # The switcher hrefs: the current path with `locale` set, so whatever query
  # the page already carries, which the consent page does, survives the switch.
  defp locale_hrefs(conn) do
    for locale <- Gettext.known_locales(Backend) do
      params = Map.put(conn.query_params, "locale", locale)
      {locale, conn.request_path <> "?" <> URI.encode_query(params)}
    end
  end

  defp resolve(conn, requested) do
    known(requested) || known(conn.cookies[@cookie]) || from_header(conn) ||
      Gettext.get_locale(Backend)
  end

  defp set_lang(conn, requested) do
    case known(requested) do
      nil -> raw_tag(conn)
      locale -> bcp47(locale)
    end
  end

  # The first tag the browser asked for, exactly as sent: `en-GB` stays `en-GB`
  # so a set that localizes on the region is reached.
  defp raw_tag(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _rest] ->
        header |> String.split(",") |> hd() |> String.split(";") |> hd() |> String.trim()

      [] ->
        nil
    end
  end

  defp from_header(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _rest] ->
        header
        |> String.split(",")
        |> Enum.map(&tag/1)
        |> Enum.find_value(&known/1)

      [] ->
        nil
    end
  end

  # A language tag is `lang-region;q=...`: the quality is dropped and the region
  # keeps its underscore form, so `pt-BR` reads as the shipped `pt_BR`.
  defp tag(part),
    do: part |> String.split(";") |> hd() |> String.trim() |> String.replace("-", "_")

  defp bcp47(locale), do: String.replace(locale, "_", "-")

  defp known(nil), do: nil

  # The bare language is tried as well, so `en-US` matches the shipped `en`
  # rather than falling through to the default.
  defp known(locale) do
    [locale, locale |> String.split("_") |> hd()]
    |> Enum.find(&(&1 in Gettext.known_locales(Backend)))
  end
end
