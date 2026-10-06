defmodule PesqueWeb.Plugs.Admin do
  @moduledoc """
  Requires the caller to be the server itself.

  createInviteCodes mints the only way in on a server whose registration is
  closed, so any account that can reach it can hand out more accounts, and
  PDS_REGISTRATION=closed stops meaning anything after the first account it
  admits. describeServer advertises inviteCodeRequired to every client that
  asks, so this is the difference between a control a server advertises and
  one it only appears to have.

  The check is that the authenticated DID is the server's own DID, which is
  the honest answer under :conformant_single: there the single account *is*
  did:web:<host>, so the server identity is an account and can hold a
  session.

  Under :path_multi there is no server identity to be. Identity.did() is
  did:web:<host> with no user segment, and no account is ever created with
  that DID (path_multi_account/1 always appends :user:<username>), so nothing
  can hold a session for it and this plug refuses every caller, operator
  included. That topology needs a configured operator list instead:
  `config :pesque, :admin_dids, ["did:web:example.com:user:alice"]`, checked
  against conn.assigns.did. That check is not implemented here rather than
  implemented and shipped without the config that makes it work, since an
  empty list that means "nobody" and one that means "the server" are the same
  code with different answers.
  """

  alias Pesque.Identity
  alias PesqueWeb.Xrpc

  require Logger

  def init(opts), do: opts

  # 403 rather than 401: the caller is authenticated, they are just not the
  # operator, and telling them to log in again would be a lie about what is
  # wrong. The log names the DID because an operator reaching this and being
  # refused is a configuration problem worth seeing, and a DID is not a
  # secret on a server that publishes it in describeServer.
  def call(conn, _opts) do
    did = conn.assigns[:did]

    if did == Identity.did() do
      conn
    else
      Logger.warning("refused an operator request: the caller is not the server",
        route: conn.request_path,
        did: did
      )

      Xrpc.error(
        conn,
        403,
        "AuthenticationRequired",
        "this endpoint is for the server operator"
      )
    end
  end
end
