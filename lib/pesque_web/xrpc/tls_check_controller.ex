defmodule PesqueWeb.Xrpc.TlsCheckController do
  @moduledoc """
  Caddy's on-demand-TLS ask endpoint: may a certificate be issued for `domain`?

  The shipped Caddyfile serves the hostname and every subdomain of it with
  `tls { on_demand }`, so Caddy calls here before it mints any certificate
  and treats every non-2xx answer as a refusal: 200 for a name this server
  owns, 403 for everything else. There is no auth, because handle existence
  is already public (resolveHandle answers the same question).
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
