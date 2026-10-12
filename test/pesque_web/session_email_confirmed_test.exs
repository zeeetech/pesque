defmodule PesqueWeb.SessionEmailConfirmedTest do
  @moduledoc """
  emailConfirmed rides with the email, in getSession and createSession alike,
  and only where the email is visible.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts

  @password "hunter2hunter2"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "getSession reports an unconfirmed email", ctx do
    body = session(ctx.token)

    assert body["email"] == ctx.alice.email
    assert body["emailConfirmed"] == false
  end

  test "getSession reports a confirmed email", ctx do
    :ok = confirm(ctx.alice)

    assert session(ctx.token)["emailConfirmed"] == true
  end

  test "createSession reports emailConfirmed with the email" do
    user = create_account("bob")

    body = decode(create_session(user))

    assert body["email"] == user.email
    assert body["emailConfirmed"] == false
  end

  defp create_session(user) do
    xrpc_post(
      "/xrpc/com.atproto.server.createSession",
      %{"identifier" => user.handle, "password" => @password},
      nil
    )
  end

  defp confirm(user) do
    {:ok, %{token: token}} = Accounts.request_email_confirmation(user)
    Accounts.confirm_email(user, user.email, token)
  end

  defp session(token), do: decode(xrpc_get("/xrpc/com.atproto.server.getSession", token))

  defp decode(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end
end
