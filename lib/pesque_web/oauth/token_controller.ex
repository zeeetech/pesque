defmodule PesqueWeb.OAuth.TokenController do
  @moduledoc """
  The token and revocation endpoints.

  Both take form-encoded parameters, both require a DPoP proof, and both answer
  `no-store`: a token response is a credential and must not sit in a shared
  cache.

  The token endpoint handles two grants and refuses anything else. The
  authorization_code grant validates PKCE and the DPoP binding; the
  refresh_token grant rotates. A confidential client adds a client assertion,
  which is checked here against the client's own published keys and the same
  DPoP key the session was created with.

  Revocation follows RFC 7009: an unknown token is not an error, because
  telling a caller whether the token it presented existed is a way of testing
  guesses.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.OAuth
  alias Pesque.OAuth.Client
  alias Pesque.OAuth.ClientAssertion
  alias PesqueWeb.OAuth.Errors
  alias PesqueWeb.OAuth.Proof

  def token(conn, params) do
    with {:ok, checked} <- Proof.check(conn),
         :ok <- authenticate_client(params),
         {:ok, response} <- grant(params, checked.assigns.dpop_jkt) do
      checked
      |> no_store()
      |> Proof.with_nonce()
      |> json(response)
    else
      {:error, reason, failed} -> fail(failed, reason)
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp grant(%{"grant_type" => "authorization_code"} = params, jkt) do
    OAuth.exchange_code(params, jkt)
  end

  defp grant(%{"grant_type" => "refresh_token"} = params, jkt) do
    OAuth.refresh(params, jkt)
  end

  defp grant(_params, _jkt), do: {:error, :unsupported_grant_type}

  # A client that says it is confidential has to prove it. The assertion is
  # checked on every request, not once at PAR, because the spec has a server
  # re-fetch the client's keys and reject a session whose key has gone: an
  # assertion that stops verifying is a client that has rotated or revoked.
  defp authenticate_client(params) do
    if ClientAssertion.requested?(params), do: verify_assertion(params), else: :ok
  end

  defp verify_assertion(params) do
    with {:ok, client_id} <- client_id(params),
         {:ok, metadata} <- Client.resolve(client_id),
         true <- Client.confidential?(metadata),
         {:ok, _auth} <-
           ClientAssertion.verify(
             client_id,
             metadata,
             params["client_assertion_type"],
             params["client_assertion"]
           ) do
      :ok
    else
      false -> {:error, :invalid_client_assertion}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_id(%{"client_id" => client_id}) when is_binary(client_id) and client_id != "",
    do: {:ok, client_id}

  defp client_id(_params), do: {:error, :invalid_client_assertion}

  def revoke(conn, params) do
    with {:ok, checked} <- Proof.check(conn) do
      _ = OAuth.revoke(params["token"])
      checked |> no_store() |> Proof.with_nonce() |> send_resp(200, "")
    else
      {:error, reason, failed} -> fail(failed, reason)
    end
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp fail(conn, reason) do
    {status, code, description} = Errors.to_oauth(reason)

    conn
    |> no_store()
    |> put_status(status)
    |> json(%{"error" => code, "error_description" => description})
    |> halt()
  end
end
