defmodule PesqueWeb.Xrpc.TlsCheckController do
  @moduledoc """
  Caddy's on-demand-TLS ask endpoint: may a certificate be issued for `domain`?

  The shipped Caddyfile serves the hostname and every subdomain of it with
  `tls { on_demand }`, so Caddy calls here before it mints any certificate
  under the wildcard label and treats every non-2xx answer as a refusal. The
  status is the whole contract: 200 for a name this server owns, 403 for
  everything else, and the body carries nothing a certificate check needs.

  The allowed names are the server's own hostname and the handles its accounts
  table carries. Nothing else earns a certificate: a name no client resolves
  here is a name whose certificate would serve no account, and a wildcard of
  the hostname is exactly what turns a name a stranger sends into a question
  about an account row instead of a free certificate.

  There is no auth and no configuration. Handle existence is already public
  (resolveHandle and the DNS records answer the same question), so a gate here
  would hide nothing; the route runs behind the read budget, which is the
  whole cost of one indexed row.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts

  def show(conn, %{"domain" => domain}) when is_binary(domain) do
    if allowed?(domain) do
      send_resp(conn, 200, "")
    else
      send_resp(conn, 403, "")
    end
  end

  # A request without a name is a name that is not allowed, not an error:
  # Caddy only reads the status, and 403 is the answer it acts on either way.
  def show(conn, _params), do: send_resp(conn, 403, "")

  defp allowed?(domain) do
    name = domain |> String.trim() |> String.downcase()

    name != "" and (name == server_host() or hosted_handle?(name))
  end

  # The name Caddy asks about is the TLS name on the wire and never carries a
  # port, while the configured hostname can under a non-default port, so the
  # port is dropped from this side before the two are compared.
  defp server_host do
    Pesque.hostname() |> String.split(":", parts: 2) |> hd() |> String.downcase()
  end

  defp hosted_handle?(name), do: match?({:ok, _did}, Accounts.resolve_handle(name))
end
