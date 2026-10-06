defmodule PesqueWeb.Plugs.Auth do
  @moduledoc """
  Requires a valid access token for an account this server hosts.

  Two kinds of token are accepted and both end up in the same two assigns, so
  nothing downstream knows which one arrived:

    * an OAuth access token, ES256 over the key published in the JWKS, bound
      to a DPoP key, and gated on the scopes it was granted
    * a legacy session token, HS256 over this server's secret, gated on the
      one scope it was issued with

  Which is which is decided by the `alg` in the token's own header rather than
  by trying one verifier and falling back to the other. A fallback would mean
  a token that failed the OAuth check gets a second chance against the legacy
  one, and the answer to "which verification failed" would stop being
  meaningful. It also means nothing is ever verified as a kind it did not
  claim: an `alg` this server does not issue is refused outright.

  An OAuth token is only usable with a DPoP proof over this very request, from
  the key the session was minted for. That is checked after the token verifies
  and never skipped: a request carrying an OAuth token without a proof is
  refused rather than served, and the refusal is one a client can act on,
  because a proof that needs the server nonce comes back as `use_dpop_nonce`
  with the nonce in `DPoP-Nonce`.

  The account is looked up, not inferred from the token's subject. A validly
  signed token for an account this server does not host has no one behind it,
  so it is rejected the same way a bad signature is.

  The reason is logged because a stranger scanning, a client with a wrong
  clock and a user whose session broke all look identical from outside, and
  only the first two are worth knowing about. No token, proof or assertion is
  ever logged.
  """

  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.OAuth
  alias Pesque.OAuth.Jwt
  alias Pesque.OAuth.Scopes
  alias Pesque.Secret
  alias Pesque.Token
  alias PesqueWeb.OAuth.Proof
  alias PesqueWeb.Xrpc
  alias PesqueWeb.Xrpc.Errors

  require Logger

  @doc "The router option naming what a route needs: `:read`, `:write` or `:account`."
  def default_permission, do: :read

  def init(opts), do: opts

  def call(conn, opts) do
    permission = Keyword.get(opts, :permission, default_permission())

    case authenticate(conn, permission) do
      {:ok, conn, user} ->
        conn
        |> assign(:did, user.did)
        |> assign(:current_user, user)

      {:error, reason, failed} ->
        Logger.warning("rejected request: #{describe(reason)}", route: conn.request_path)

        refuse(failed, reason)
    end
  end

  # Every arm answers {:ok, conn, user} or {:error, reason, conn}, so the caller
  # has one shape to handle and the failed conn is the one carrying whatever
  # the proof check put on it, such as the nonce a client has to retry with.
  defp authenticate(conn, permission) do
    with {:ok, token} <- bearer(conn),
         {:ok, kind, claims} <- verify(token),
         {:ok, conn} <- prove(conn, kind, token, claims),
         :ok <- authorize(kind, claims, permission),
         {:ok, user} <- account(claims) do
      {:ok, conn, user}
    else
      {:error, reason, failed} -> {:error, reason, failed}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  # A token arriving without the prefix is not a token this server issues in
  # either scheme, so it is refused here rather than parsed twice.
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["DPoP " <> token] when token != "" -> {:ok, token}
      [_ | _] -> {:error, :malformed_authorization}
      [] -> {:error, :no_bearer_token}
    end
  end

  # The two verifiers answer :invalid_token, which on the XRPC surface means
  # something narrower (a token for another account), so the reason is renamed
  # here rather than translated in two places downstream. A signature that did
  # not verify, an expired token, a revoked one and a tampered header are all
  # the same answer to the client and one reason here.
  defp verify(token) do
    case Jwt.alg(token) do
      {:ok, "ES256"} -> oauth(token)
      {:ok, "HS256"} -> session(token)
      _other -> {:error, :rejected_token}
    end
  end

  defp oauth(token) do
    case OAuth.verify_access_token(token) do
      {:ok, claims} -> {:ok, :oauth, claims}
      {:error, _reason} -> {:error, :rejected_token}
    end
  end

  defp session(token) do
    case Token.verify(token, Secret.get(), "com.atproto.access") do
      {:ok, claims} -> {:ok, :session, claims}
      {:error, _reason} -> {:error, :rejected_token}
    end
  end

  # A legacy session token carries no proof and needs none: it is HS256 over a
  # secret only this server holds, and the bearer of it is whoever holds it.
  # The OAuth path has to show the key instead, which is what DPoP is for.
  defp prove(conn, :session, _token, _claims), do: {:ok, conn}

  defp prove(conn, :oauth, token, claims) do
    case Proof.check(conn, token) do
      {:ok, checked} ->
        if secure_equal?(checked.assigns.dpop_jkt, OAuth.jkt(claims)) do
          {:ok, Proof.with_nonce(checked)}
        else
          {:error, :dpop_key_mismatch, conn}
        end

      {:error, reason, failed} ->
        {:error, reason, failed}
    end
  end

  # The thumbprint is not a secret, but comparing it in constant time costs
  # nothing and means nothing about this path depends on how the strings
  # happened to be laid out in memory.
  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  # A legacy token is one scope that reaches everything, which is what it was
  # issued as, so it is not narrowed here. An OAuth token is narrowed to what
  # it was actually granted.
  defp authorize(:session, _claims, _permission), do: :ok

  defp authorize(:oauth, claims, permission) do
    if Scopes.permit?(Map.get(claims, "scope", ""), permission) do
      :ok
    else
      {:error, {:insufficient_scope, permission}}
    end
  end

  defp account(claims) do
    case Accounts.get_user(claims["sub"]) do
      %User{} = user -> {:ok, user}
      _other -> {:error, :unknown_account}
    end
  end

  # The refusal is an XRPC error the way every other one here is, plus the
  # header the OAuth profile requires on an authenticated request. A client
  # that reads only the header still learns which of the two things to fix:
  # the token or the proof.
  defp refuse(conn, reason) do
    {status, name, message} = Errors.to_xrpc(reason)

    conn
    |> put_resp_header("www-authenticate", Errors.to_challenge(reason))
    |> Xrpc.error(status, name, message)
  end

  defp describe(:no_bearer_token), do: "no bearer token"
  defp describe(:malformed_authorization), do: "malformed authorization header"
  defp describe(:rejected_token), do: "token did not verify"
  defp describe(:unknown_account), do: "token named an account this server does not host"
  defp describe({:insufficient_scope, permission}), do: "token lacks #{permission}"
  defp describe(:use_dpop_nonce), do: "proof needs the server nonce"

  defp describe(reason) when reason in [:missing_dpop_proof, :dpop_key_mismatch],
    do: "dpop proof rejected"

  defp describe(_reason), do: "dpop proof did not verify"
end
