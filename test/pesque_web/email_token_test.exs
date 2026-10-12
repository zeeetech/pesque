defmodule PesqueWeb.EmailTokenTest do
  @moduledoc """
  The four email-code endpoints: requestEmailConfirmation/confirmEmail and
  requestPasswordReset/resetPassword.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.EmailToken
  alias Pesque.Accounts.PasswordResetToken
  alias Pesque.Repo

  @request_email "/xrpc/com.atproto.server.requestEmailConfirmation"
  @confirm_email "/xrpc/com.atproto.server.confirmEmail"
  @request_update "/xrpc/com.atproto.server.requestEmailUpdate"
  @update_email "/xrpc/com.atproto.server.updateEmail"
  @request_reset "/xrpc/com.atproto.server.requestPasswordReset"
  @reset "/xrpc/com.atproto.server.resetPassword"

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  describe "requestEmailConfirmation" do
    test "needs a token" do
      assert xrpc_post(@request_email, %{}, nil).status == 401
    end

    test "records a code and answers an empty object", ctx do
      conn = xrpc_post(@request_email, %{}, ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
      assert Repo.aggregate(EmailToken, :count) == 1
    end
  end

  describe "confirmEmail" do
    test "spends the code and stamps the account", ctx do
      code = issue_email_code(ctx.alice)

      conn = xrpc_post(@confirm_email, %{"email" => ctx.alice.email, "token" => code}, ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
      assert Accounts.get_user(ctx.alice.did).email_confirmed_at
    end

    test "an email that is not the account's answers InvalidEmail", ctx do
      code = issue_email_code(ctx.alice)

      conn =
        xrpc_post(@confirm_email, %{"email" => "else@localhost", "token" => code}, ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidEmail"
    end

    test "an unknown code answers InvalidToken", ctx do
      conn =
        xrpc_post(@confirm_email, %{"email" => ctx.alice.email, "token" => "nope"}, ctx.token)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidToken"
    end

    test "a spent code answers InvalidToken", ctx do
      code = issue_email_code(ctx.alice)
      xrpc_post(@confirm_email, %{"email" => ctx.alice.email, "token" => code}, ctx.token)

      conn = xrpc_post(@confirm_email, %{"email" => ctx.alice.email, "token" => code}, ctx.token)

      assert conn.status == 401
    end
  end

  describe "requestPasswordReset" do
    test "is reachable with no token and mints a code silently", ctx do
      conn = xrpc_post(@request_reset, %{"email" => ctx.alice.email}, nil)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
      assert Repo.aggregate(PasswordResetToken, :count) == 1
    end

    test "an unknown address answers the same and mints nothing", _ctx do
      conn = xrpc_post(@request_reset, %{"email" => "nobody@localhost"}, nil)

      assert conn.status == 200
      assert Repo.aggregate(PasswordResetToken, :count) == 0
    end

    test "needs an email" do
      assert xrpc_post(@request_reset, %{}, nil).status == 400
    end
  end

  describe "resetPassword" do
    test "spends the code and changes the password", ctx do
      code = issue_reset_code(ctx.alice)

      conn = xrpc_post(@reset, %{"token" => code, "password" => "a new password"}, nil)

      assert conn.status == 200
      assert {:ok, _user} = Accounts.verify_login(ctx.alice.handle, "a new password")
    end

    test "a bad code answers InvalidToken", _ctx do
      conn = xrpc_post(@reset, %{"token" => "nope", "password" => "a new password"}, nil)

      assert conn.status == 401
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidToken"
    end

    test "a too-short password is refused", ctx do
      code = issue_reset_code(ctx.alice)

      conn = xrpc_post(@reset, %{"token" => code, "password" => "short"}, nil)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    end
  end

  describe "requestEmailUpdate / updateEmail" do
    test "an unconfirmed account needs no token to move", ctx do
      conn = xrpc_post(@request_update, %{}, ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"tokenRequired" => false}

      conn = xrpc_post(@update_email, %{"email" => "new@localhost"}, ctx.token)

      assert conn.status == 200
      assert Accounts.get_user(ctx.alice.did).email == "new@localhost"
    end

    test "a confirmed account is told a token is required, then accepts the code", ctx do
      confirmed = confirm(ctx.alice)

      conn = xrpc_post(@request_update, %{}, ctx.token)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"tokenRequired" => true}

      # Without the code the move is refused with the lexicon's own error.
      conn = xrpc_post(@update_email, %{"email" => "new@localhost"}, ctx.token)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["error"] == "TokenRequired"

      {:ok, %{token: code}} = Accounts.request_email_update(confirmed)

      conn = xrpc_post(@update_email, %{"email" => "new@localhost", "token" => code}, ctx.token)

      assert conn.status == 200

      updated = Accounts.get_user(ctx.alice.did)
      assert updated.email == "new@localhost"
      # The new address is unconfirmed until its own code is spent.
      assert is_nil(updated.email_confirmed_at)
    end

    test "needs an authenticated session", _ctx do
      assert xrpc_post(@update_email, %{"email" => "new@localhost"}, nil).status == 401
    end
  end

  defp confirm(user) do
    {:ok, %{token: token}} = Accounts.request_email_confirmation(user)
    :ok = Accounts.confirm_email(user, user.email, token)
    Accounts.get_user(user.did)
  end

  defp issue_email_code(user) do
    {:ok, %{token: token}} = Accounts.request_email_confirmation(user)
    token
  end

  defp issue_reset_code(user) do
    {:ok, %{token: token}} = Accounts.request_password_reset(user)
    token
  end
end
