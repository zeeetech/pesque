defmodule PesqueWeb.Plugs.AdminTest do
  @moduledoc """
  Who may mint an invite code.

  createInviteCodes sits behind authentication, which is not the same thing as
  being the operator: on a server whose registration is closed, any account
  that can reach it can hand out more accounts, so the first account admitted
  decides who else gets in. That is the whole control describeServer
  advertises as inviteCodeRequired.

  A plug test rather than a request test, because the route is not wired yet
  (see the report: the router is owned by another change). What is pinned here
  is the plug's decision, which is the part that has to hold once it is.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Pesque.Identity
  alias PesqueWeb.Plugs.Admin

  setup do
    put_mode(:conformant_single)
  end

  test "the server's own account passes" do
    conn = conn_for(Identity.did())

    refute conn.halted
    assert conn.status == nil
  end

  test "any other account is refused with a 403" do
    conn = conn_for("did:web:example.com:user:alice")

    assert conn.halted
    assert conn.status == 403

    body = JSON.decode!(conn.resp_body)
    assert body["error"] == "AuthenticationRequired"
  end

  # 401 would tell an authenticated caller to log in again, which is not the
  # problem and sends an operator looking at their session instead of at their
  # configuration.
  test "a refused caller is not told to authenticate" do
    assert conn_for("did:web:example.com:user:alice").status == 403
  end

  test "a caller with no DID at all is refused" do
    conn =
      :get
      |> conn("/xrpc/com.atproto.server.createInviteCodes")
      |> Admin.call([])

    assert conn.halted
    assert conn.status == 403
  end

  test "the refusal does not leak the token or the password" do
    conn = conn_for("did:web:example.com:user:alice")

    refute conn.resp_body =~ "Bearer"
    refute conn.resp_body =~ "eyJ"
  end

  defp conn_for(did) do
    :post
    |> conn("/xrpc/com.atproto.server.createInviteCodes")
    |> assign(:did, did)
    |> Admin.call([])
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
