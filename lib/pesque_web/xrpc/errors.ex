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

  def to_xrpc(:account_exists),
    do: {400, "AccountExists", "this server already hosts its account"}

  def to_xrpc(:handle_not_available),
    do: {400, "HandleNotAvailable", "handle is not available on this server"}

  def to_xrpc(:password_too_short),
    do: {400, "InvalidRequest", "password must be at least 8 characters"}

  def to_xrpc(:email_required), do: {400, "InvalidRequest", "an email is required"}

  def to_xrpc(:email_taken),
    do: {400, "InvalidRequest", "email is already used as a handle on this server"}

  def to_xrpc(:missing_fields), do: {400, "InvalidRequest", "account could not be created"}
  def to_xrpc(:wrong_repo), do: {400, "InvalidRequest", "repo must be the authenticated account"}
  def to_xrpc(:empty), do: {400, "InvalidRequest", "blob body is empty"}

  def to_xrpc(:too_large),
    do: {400, "InvalidRequest", "blob is larger than #{Blob.max_bytes()} bytes"}

  def to_xrpc(:unwritable), do: {500, "InternalServerError", "blob could not be written to disk"}
  def to_xrpc(:not_found), do: {400, "BlobNotFound", "no blob at that CID for this repo"}
end
