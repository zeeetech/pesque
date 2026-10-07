defmodule PesqueWeb.OAuth.Errors do
  @moduledoc """
  The one place an OAuth reason becomes a status, an error code and a message.

  OAuth errors are not XRPC errors. The body is `error` and
  `error_description`, carrying the codes RFC 6749 and the atproto profile
  name, and a browser client switches on the code, so the mapping lives here
  instead of being spelled out at each endpoint. `PesqueWeb.Xrpc.Errors` is the
  same idea for the XRPC surface and stays that shape.

  Every clause is a reason Pesque.OAuth or Pesque.OAuth.DPoP can actually
  answer, so a new reason fails loudly rather than turning into a generic
  answer no client can act on.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @spec to_oauth(term()) :: {integer(), String.t(), String.t()}

  def to_oauth(:invalid_client_id),
    do: {400, "invalid_client", "client_id is not a valid https URL"}

  def to_oauth(:client_id_mismatch),
    do: {400, "invalid_client", "client_id does not match the published document"}

  def to_oauth(:invalid_client_metadata),
    do: {400, "invalid_client", "the client metadata document is not usable"}

  def to_oauth(:unsupported_auth_method),
    do: {400, "invalid_client", "token_endpoint_auth_method is not supported"}

  def to_oauth(:no_client_keys),
    do: {400, "invalid_client", "the client published no keys"}

  def to_oauth(:invalid_client_assertion),
    do: {400, "invalid_client", "the client assertion did not verify"}

  def to_oauth(:client_metadata_too_large),
    do: {400, "invalid_client", "the client metadata document is too large"}

  def to_oauth(:forbidden_address),
    do: {400, "invalid_client", "the client metadata host is not on the public internet"}

  def to_oauth({:client_metadata_status, status}),
    do: {400, "invalid_client", "the client metadata document answered #{status}"}

  def to_oauth({:client_metadata_unreachable, reason}),
    do:
      {400, "invalid_client",
       "the client metadata document could not be fetched: #{inspect(reason)}"}

  def to_oauth(:dpop_not_bound),
    do: {400, "invalid_client", "dpop_bound_access_tokens must be true"}

  def to_oauth(:unsupported_response_type),
    do: {400, "unsupported_response_type", "only the code response type is supported"}

  def to_oauth(:invalid_pkce),
    do: {400, "invalid_request", "a code_challenge with method S256 is required"}

  def to_oauth(:invalid_code_verifier),
    do: {400, "invalid_grant", "the code verifier does not match the challenge"}

  def to_oauth(:missing_state),
    do: {400, "invalid_request", "state is required"}

  def to_oauth(:invalid_redirect_uri),
    do: {400, "invalid_request", "the redirect_uri is not one the client registered"}

  def to_oauth(:invalid_scope),
    do: {400, "invalid_scope", "a requested scope is not declared in the client metadata"}

  def to_oauth({:unsupported_scope, scope}),
    do: {400, "invalid_scope", "this server does not grant #{scope}"}

  def to_oauth(:missing_scope), do: {400, "invalid_scope", "scope is required"}

  def to_oauth(:missing_atproto_scope),
    do: {400, "invalid_scope", "the atproto scope is required"}

  def to_oauth(:openid_not_supported),
    do: {400, "invalid_scope", "openid is not compatible with atproto"}

  def to_oauth({:missing_parameter, key}),
    do: {400, "invalid_request", "#{key} is required"}

  def to_oauth(:invalid_login_hint),
    do: {400, "invalid_request", "login_hint names no account on this server"}

  def to_oauth(:login_hint_mismatch),
    do: {400, "invalid_request", "login_hint names another account"}

  def to_oauth(:invalid_request_uri),
    do: {400, "invalid_request", "the request_uri is unknown"}

  def to_oauth(:request_expired),
    do: {400, "invalid_request", "the request_uri has expired"}

  def to_oauth(:request_already_used),
    do: {400, "invalid_request", "the request_uri was already used"}

  def to_oauth(:request_not_stored),
    do: {500, "server_error", "the authorization request could not be stored"}

  def to_oauth(:token_not_stored),
    do: {500, "server_error", "the tokens could not be stored"}

  def to_oauth(:invalid_grant),
    do: {400, "invalid_grant", "the code or refresh token is not valid"}

  def to_oauth(:unsupported_grant_type),
    do: {400, "unsupported_grant_type", "only authorization_code and refresh_token are supported"}

  def to_oauth(:missing_dpop_proof),
    do: {400, "invalid_dpop_proof", "a DPoP proof is required on this endpoint"}

  # A token the parser could not take apart is the same failure as a token
  # whose signature does not verify: the client sent something that is not a
  # proof, and the description should not tell it which part was wrong.
  def to_oauth(reason) when reason in [:invalid_dpop_proof, :malformed_jwt],
    do: {400, "invalid_dpop_proof", "the DPoP proof did not verify"}

  def to_oauth(:unsupported_jwk),
    do: {400, "invalid_dpop_proof", "the DPoP key is not a P-256 key"}

  def to_oauth(:htm_mismatch),
    do: {400, "invalid_dpop_proof", "the DPoP htm does not match the request method"}

  def to_oauth(:htu_mismatch),
    do: {400, "invalid_dpop_proof", "the DPoP htu does not match the request URL"}

  def to_oauth(:missing_jti),
    do: {400, "invalid_dpop_proof", "the DPoP proof carries no jti"}

  def to_oauth(:missing_iat),
    do: {400, "invalid_dpop_proof", "the DPoP proof carries no iat"}

  def to_oauth(:expired_dpop_proof),
    do: {400, "invalid_dpop_proof", "the DPoP proof is outside its accepted window"}

  def to_oauth(:ath_mismatch),
    do: {400, "invalid_dpop_proof", "the DPoP ath does not match the access token"}

  def to_oauth(:ath_not_allowed),
    do:
      {400, "invalid_dpop_proof",
       "the DPoP proof carries ath on a request that presented no access token"}

  # The one a client is expected to act on rather than give up: it means "send
  # me a nonce first", and it arrives with that nonce in the response header.
  def to_oauth(:use_dpop_nonce),
    do: {400, "use_dpop_nonce", "the DPoP proof needs the server nonce from the last response"}

  def to_oauth(:invalid_credentials),
    do: {401, "access_denied", "invalid identifier or password"}

  def to_oauth(:invalid_token),
    do: {401, "invalid_token", "the token is unknown or no longer live"}

  @doc """
  Renders a reason as the OAuth error response: status, JSON body, `no-store`.

  The conn may already carry a `DPoP-Nonce` header set by the proof check, so
  the response keeps whatever is on it. Halted, because both controllers answer
  this from a `with` and must not fall through.
  """
  def render(conn, reason) do
    {status, code, description} = to_oauth(reason)

    conn
    |> no_store()
    |> put_status(status)
    |> json(%{"error" => code, "error_description" => description})
    |> halt()
  end

  @doc "The `no-store` every token, nonce or error response carries."
  def no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
