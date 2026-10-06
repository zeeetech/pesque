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
  session. That is the default topology.

  Under :path_multi there is no server identity to be. Identity.did() is
  did:web:<host> with no user segment, and no account is ever created with
  that DID (path_multi_account/1 always appends :user:<username>), so nothing
  can hold a session for it. That topology names its operator instead:

      config :pesque, admin_dids: ["did:web:example.com:user:alice"]

  An unset or empty list is not "everyone" and not a fallback to the server
  DID: it means the server identity only, so a :path_multi server with no list
  configured refuses every caller including the operator. That is the
  uncomfortable answer and it is the right one, because a closed-registration
  server that admits nobody is recoverable by adding one line of config,
  whereas one that admits the first account to ask is not recoverable at all.
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

    if operator?(did) do
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

  # The server identity always qualifies, under any topology, because under
  # :conformant_single it is the operator and under :path_multi it is simply
  # unreachable rather than wrong.
  defp operator?(did), do: did == Identity.did() or did in operators()

  defp operators, do: Application.get_env(:pesque, :admin_dids, [])
end
