defmodule PesqueWeb.Xrpc.Errors do
  @moduledoc """
  The one place a reason from the domain becomes an XRPC error.

  Status, name and message are decided here and nowhere else, so two endpoints
  that fail for the same reason answer the same body. Every clause is a reason
  Pesque.RepoServer, Pesque.Accounts or Pesque.Blob can actually answer; a
  reason without a clause fails loudly rather than turning into a generic
  answer no client can act on.
  """

  alias Pesque.Blob

  # Every way a DPoP proof fails to answer for a request. They share a status,
  # a name and a message, and a client is not told which part was wrong: a
  # proof that does not verify is a proof that does not verify.
  @dpop_proof_failures [
    :missing_dpop_proof,
    :invalid_dpop_proof,
    :unsupported_jwk,
    :htm_mismatch,
    :htu_mismatch,
    :missing_jti,
    :missing_iat,
    :expired_dpop_proof,
    :ath_mismatch,
    :ath_not_allowed,
    :malformed_jwt,
    :dpop_key_mismatch
  ]

  @spec to_xrpc(term()) :: {integer(), String.t(), String.t()}

  def to_xrpc(:record_exists),
    do: {400, "InvalidRecordKey", "a record already exists at that key"}

  def to_xrpc(:invalid_collection), do: {400, "InvalidRequest", "collection is not a valid NSID"}
  def to_xrpc(:invalid_rkey), do: {400, "InvalidRecordKey", "rkey is not valid"}

  def to_xrpc({:type_mismatch, found, collection}),
    do: {400, "InvalidRequest", "record $type #{found} is not #{collection}"}

  def to_xrpc(:unknown_collection),
    do: {400, "InvalidRequest", "this server has no lexicon for that collection"}

  def to_xrpc(:invalid_link), do: {400, "InvalidRequest", "a $link is not a parseable CID"}
  def to_xrpc(:invalid_bytes), do: {400, "InvalidRequest", "a $bytes value is not valid base64"}

  def to_xrpc(:unencodable),
    do: {400, "InvalidRequest", "record holds a value DAG-CBOR cannot encode"}

  def to_xrpc(:record_not_found), do: {400, "RecordNotFound", "no record at that key"}

  def to_xrpc(:invalid_swap),
    do: {400, "InvalidSwap", "swapCommit does not match the current repo commit"}

  def to_xrpc(:invalid_writes), do: {400, "InvalidRequest", "writes must be an array"}

  def to_xrpc(:invalid_write),
    do: {400, "InvalidRequest", "a write is not a create, update or delete"}

  def to_xrpc({:unsupported_write, type}),
    do: {400, "InvalidRequest", "write action #{type} is not supported"}

  def to_xrpc(:invalid_audience),
    do: {400, "InvalidRequest", "aud must be a DID or a did#serviceId reference"}

  def to_xrpc(:invalid_lxm),
    do: {400, "InvalidRequest", "lxm must be a valid NSID"}

  def to_xrpc(:bad_expiration),
    do: {400, "BadExpiration", "the requested expiration is in the past or too far ahead"}

  def to_xrpc(:account_exists),
    do: {400, "AccountExists", "this server already hosts its account"}

  def to_xrpc(:unsupported_did),
    do: {400, "UnsupportedDomain", "did must be a did:web this server serves for the handle"}

  def to_xrpc(:invalid_car),
    do: {400, "InvalidRequest", "the CAR could not be read as a repo"}

  def to_xrpc(:handle_not_available),
    do: {400, "HandleNotAvailable", "handle is not available on this server"}

  # Importing a DID or moving a did:plc handle to a foreign domain requires the
  # handle to resolve to the DID, in both directions. A handle that resolves to
  # nothing or to another DID, and a DID document that does not name the handle,
  # are each refused before a row is written.
  def to_xrpc(:invalid_handle),
    do: {400, "InvalidHandle", "handle is not a valid handle"}

  def to_xrpc(:disallowed_handle),
    do: {400, "InvalidHandle", "handle is under a domain that cannot resolve"}

  def to_xrpc(:handle_unresolved),
    do: {400, "HandleNotFound", "the handle does not resolve to a DID"}

  def to_xrpc(:handle_mismatch),
    do: {400, "HandleNotFound", "the handle resolves to a different DID"}

  def to_xrpc(:handle_not_claimed),
    do: {400, "UnresolvableDid", "the DID document does not claim the handle"}

  def to_xrpc(:key_unavailable),
    do: {500, "InternalServerError", "the server signing key could not be loaded"}

  # The PLC directory. A refused or unreachable submission is a server-side
  # failure: the account was not created, and a retry is the client's move.
  def to_xrpc(:plc_unreachable),
    do: {500, "InternalServerError", "the PLC directory could not be reached"}

  def to_xrpc({:plc_unreachable, _reason}),
    do: {500, "InternalServerError", "the PLC directory could not be reached"}

  def to_xrpc({:plc_status, _status}),
    do: {500, "InternalServerError", "the PLC directory refused the operation"}

  def to_xrpc(:plc_operation_missing),
    do: {500, "InternalServerError", "the account has no PLC operation to update"}

  def to_xrpc({:rotation_key_unreadable, _reason}),
    do: {500, "InternalServerError", "the account rotation key could not be read"}

  def to_xrpc(:pds_mismatch),
    do: {400, "InvalidRequest", "the DID document does not point at this server"}

  def to_xrpc(:pds_missing),
    do: {400, "InvalidRequest", "the DID document names no atproto_pds service"}

  # An operation a migrating account submitted. Each is a constraint this
  # server puts on the identity before it lets the directory see the operation,
  # so each names the one field that did not hold rather than a generic refusal.
  def to_xrpc(:plc_operation_invalid),
    do: {400, "InvalidRequest", "operation is not a valid PLC operation"}

  def to_xrpc(:plc_endpoint_mismatch),
    do: {400, "InvalidRequest", "the operation's PDS endpoint is not this server"}

  def to_xrpc(:plc_signing_key_mismatch),
    do: {400, "InvalidRequest", "the operation's signing key is not this account's"}

  def to_xrpc(:plc_handle_mismatch),
    do: {400, "InvalidRequest", "the operation does not claim this account's handle"}

  def to_xrpc(:not_a_plc_account),
    do: {400, "InvalidRequest", "this account is not a did:plc identity"}

  # An import proves control of the DID it claims with a service-auth token
  # signed by the DID's own key. A token that does not verify, does not name
  # this server, or is for another method proves nothing, so it is refused the
  # same way a missing one is.
  def to_xrpc(:invalid_service_auth),
    do: {401, "AuthenticationRequired", "a valid service auth token is required"}

  def to_xrpc(:unresolvable_did),
    do: {400, "UnresolvableDid", "the DID does not resolve"}

  def to_xrpc(:invalid_did), do: {400, "InvalidRequest", "did is not a valid DID"}

  def to_xrpc(:wrong_account_did),
    do: {400, "InvalidRequest", "did must be the authenticated account"}

  def to_xrpc(:invalid_password),
    do: {401, "AuthenticationRequired", "the account password is wrong"}

  def to_xrpc(:invalid_token),
    do: {401, "InvalidToken", "the token is unknown, already used, or for another account"}

  def to_xrpc(:expired_token), do: {401, "ExpiredToken", "the token has expired"}

  def to_xrpc(:deletion_token_failed),
    do: {500, "InternalServerError", "a deletion token could not be issued"}

  def to_xrpc(:session_not_issued),
    do: {500, "InternalServerError", "the session could not be issued"}

  def to_xrpc(:password_too_short),
    do: {400, "InvalidRequest", "password must be at least 8 characters"}

  def to_xrpc(:email_required), do: {400, "InvalidRequest", "an email is required"}

  def to_xrpc(:email_taken),
    do: {400, "InvalidRequest", "email is already used as a handle on this server"}

  def to_xrpc(:invalid_invite_code),
    do:
      {400, "InvalidInviteCode",
       "the invitation code is invalid, exhausted, or for another account"}

  def to_xrpc(:invite_code_required),
    do:
      {400, "InvalidInviteCode", "this server is invite only, so an invitation code is required"}

  def to_xrpc(:invalid_code_count),
    do: {400, "InvalidRequest", "codeCount must be a positive integer"}

  def to_xrpc(:invalid_use_count),
    do: {400, "InvalidRequest", "useCount must be a positive integer"}

  def to_xrpc(:missing_fields), do: {400, "InvalidRequest", "account could not be created"}
  def to_xrpc(:wrong_repo), do: {400, "InvalidRequest", "repo must be the authenticated account"}

  def to_xrpc(:account_deactivated),
    do: {400, "InvalidRequest", "the account is deactivated and must be activated first"}

  def to_xrpc(:account_not_updated),
    do: {500, "InternalServerError", "the account status could not be recorded"}

  def to_xrpc(:empty), do: {400, "InvalidRequest", "blob body is empty"}

  def to_xrpc(:too_large),
    do: {400, "InvalidRequest", "blob is larger than #{Blob.max_bytes()} bytes"}

  def to_xrpc(:unwritable), do: {500, "InternalServerError", "blob could not be written to disk"}
  def to_xrpc(:not_found), do: {400, "BlobNotFound", "no blob at that CID for this repo"}

  # SQLite has one writer, so a commit that loses the race for the write lock is
  # a retry, not a failure. 503 is what tells a client to come back rather than
  # treat the write as lost; the commit either happened or it did not, and
  # neither answer is knowable from here.
  def to_xrpc(:busy), do: {503, "InternalServerError", "the repo is busy, retry the request"}

  # The authentication plug. A rejected token, a missing or wrong DPoP proof
  # and a scope that does not reach the route are three different answers,
  # because a client can act on all three differently: get a new token, send
  # the nonce back, or ask for a scope it was not granted.
  def to_xrpc(:no_bearer_token),
    do: {401, "AuthenticationRequired", "a valid access token is required"}

  def to_xrpc(:malformed_authorization),
    do: {401, "AuthenticationRequired", "a valid access token is required"}

  def to_xrpc(:rejected_token),
    do: {401, "AuthenticationRequired", "a valid access token is required"}

  def to_xrpc(:unknown_account),
    do: {401, "AuthenticationRequired", "a valid access token is required"}

  def to_xrpc({:insufficient_scope, permission}),
    do: {403, "InsufficientScope", "this token does not grant #{permission}"}

  def to_xrpc(:use_dpop_nonce),
    do: {401, "AuthenticationRequired", "the DPoP proof needs the server nonce"}

  def to_xrpc(reason) when reason in @dpop_proof_failures,
    do: {401, "AuthenticationRequired", "a valid DPoP proof is required for this request"}

  # The WWW-Authenticate header RFC 9449 and the atproto profile require on a
  # refused request. It is what a client reads to tell the three failures
  # apart, so it is decided here next to the status rather than in the plug
  # that sends it.
  @spec to_challenge(term()) :: String.t()

  def to_challenge(:no_bearer_token), do: "DPoP"
  def to_challenge(:malformed_authorization), do: "DPoP"

  def to_challenge(reason)
      when reason in [:rejected_token, :invalid_token, :expired_token, :unknown_account],
      do: ~s(DPoP error="invalid_token")

  def to_challenge(:use_dpop_nonce),
    do:
      ~s(DPoP error="use_dpop_nonce", error_description="retry with the DPoP-Nonce from this response")

  def to_challenge(reason) when reason in @dpop_proof_failures,
    do: ~s(DPoP error="invalid_dpop_proof")

  def to_challenge({:insufficient_scope, _permission}),
    do: ~s(DPoP error="insufficient_scope")
end
