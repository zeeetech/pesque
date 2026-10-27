defmodule PesqueWeb.TlsCheckTest do
  @moduledoc """
  The ask endpoint behind Caddy's on-demand TLS.

  Caddy mints a certificate under the wildcard only when this endpoint
  answers 200 for the name, so the answers are the whole security boundary:
  the server's own hostname and the handles its accounts table carries are
  allowed, and a name nothing on this server resolves is not.
  """

  use PesqueWeb.ConnCase, async: false

  alias PesqueWeb.Endpoint

  @endpoint Endpoint

  setup do
    alice = insert_account("alice")

    %{alice: alice}
  end

  test "the server's own hostname is allowed" do
    assert tls_check(Pesque.hostname()).status == 200
  end

  test "the hostname is compared case-insensitively" do
    assert tls_check(String.upcase(Pesque.hostname())).status == 200
  end

  test "a handle this server hosts is allowed", ctx do
    assert tls_check(ctx.alice.handle).status == 200
  end

  test "a subdomain of the hostname with no account behind it is refused" do
    assert tls_check("mallory." <> Pesque.hostname()).status == 403
  end

  test "a name this server does not host is refused" do
    assert tls_check("alice.elsewhere.example").status == 403
  end

  test "an empty domain is a refusal, not an error" do
    assert tls_check("").status == 403
  end

  test "a missing domain is a refusal, not an error" do
    conn = get(build_conn(), "/xrpc/_tls-check")

    assert conn.status == 403
  end

  defp tls_check(domain) do
    get(build_conn(), "/xrpc/_tls-check?domain=" <> enc(domain))
  end
end
