defmodule PesqueWeb.Plugs.SecurityHeaders do
  @moduledoc "Baseline hardening headers on every response."

  import Plug.Conn

  alias PesqueWeb.Csp

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_header("strict-transport-security", "max-age=63072000; includeSubDomains")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", csp(conn))
  end

  # A request that accepts HTML is a page, and a page links this origin's
  # stylesheet, fonts and icon; everything else is API traffic and keeps the
  # strict policy. The pages that render HTML set their own policy too, so this
  # only has to be right for the pages Phoenix renders on its own, which are
  # the error pages. The two formats are picked from the same accept header, so
  # a request that gets an HTML error page also gets the policy that lets it
  # load the stylesheet.
  defp csp(conn) do
    case get_req_header(conn, "accept") do
      [accept | _rest] ->
        if String.contains?(accept, "text/html"), do: Csp.pages(), else: Csp.strict()

      [] ->
        Csp.strict()
    end
  end
end
