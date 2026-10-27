defmodule PesqueWeb.Plugs.Admin do
  @moduledoc """
  Requires the caller to be the server itself.

  createInviteCodes mints the only way in on a server whose registration is
  closed, so any account that can reach it can hand out more accounts, and
  PDS_REGISTRATION=closed stops meaning anything after the first account it
  admits. describeServer advertises inviteCodeRequired to every client that
  asks, so this is the difference between a control a server advertises and
  one it only appears to have.

  The check is that the authenticated DID is the operator's. Under :single the
  single account is the operator, whatever its DID method: a did:web account's
  DID is the host identity, and a did:plc account's DID is the minted one, so
  the check follows the account's stored DID. That is the default topology.

  Under :multi there is no server identity to be. Identity.did() is
  did:web:<host> with no account behind it, and no account is ever created with
  that DID, so nothing can hold a session for it. That topology names its
  operator instead:

      config :pesque, admin_dids: ["did:plc:..."]

  An unset or empty list is not "everyone" and not a fallback to the server
  DID: it means the server identity only, so a :multi server with no list
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

  # Who the operator is depends on the mode:
  #
  # Under single the single account is the operator. Its DID may be the host
  # did:web (a web account) or a minted did:plc (a plc account), so the check
  # follows the account's stored DID rather than the host identity, which under
  # single + plc no account holds. Before the account exists the host DID is the
  # fallback, so first-boot administration still works.
  #
  # Under multi no account is the server, so the host DID qualifies (it is
  # unreachable, as before) alongside any configured admin_dids.
  # A nil DID is never the operator: with no account yet single_account_did/0
  # is also nil, and `nil == nil` would otherwise admit an unauthenticated
  # caller. The caller must carry a real DID that matches.
  defp operator?(nil), do: false

  defp operator?(did) do
    operator_did?(did) or did in operators()
  end

  defp operator_did?(did) do
    case {Pesque.mode(), single_account_did()} do
      {:single, nil} -> did == Identity.did()
      {:single, account_did} -> did == account_did
      {:multi, _none} -> did == Identity.did()
    end
  end

  # The single account's DID, or nil when there is no account yet or the mode
  # is multi (where there is no single account to be the operator).
  defp single_account_did do
    with :single <- Pesque.mode(),
         {:ok, did} <- Pesque.Accounts.resolve_handle(Identity.handle()) do
      did
    else
      _none -> nil
    end
  end

  defp operators, do: Application.get_env(:pesque, :admin_dids, [])
end
