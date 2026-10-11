defmodule Pesque.Accounts.ResetPasswordTest do
  @moduledoc """
  A password reset replaces the hash and ends every session the account
  holds - the property a reset that is not a reset would fail.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.OAuth.Token
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()

    # path_multi so the account gets a handle: under conformant_single the
    # seeded server row has no handle and every account compares as taken.
    put_mode(:path_multi)

    handle = "reset" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  test "the new password verifies and the old one does not", %{user: user} do
    assert :ok = Accounts.reset_password(user, "the new password")

    assert {:ok, _user} = Accounts.verify_login(user.handle, "the new password")
    assert :error = Accounts.verify_login(user.handle, @password)
  end

  test "a password that is too short is refused and nothing changes", %{user: user} do
    assert Accounts.reset_password(user, "short") == {:error, :password_too_short}

    assert {:ok, _user} = Accounts.verify_login(user.handle, @password)
  end

  test "the account's refresh tokens are revoked", %{user: user} do
    {:ok, session} = Accounts.issue_session(user.did)

    assert :ok = Accounts.reset_password(user, "the new password")

    assert {:error, :invalid_token} = Accounts.rotate_session(session.refresh_jwt)
  end

  test "the account's OAuth tokens are revoked, access and refresh alike", %{user: user} do
    access = oauth_token(user.did, "session-1", Token.access())
    refresh = oauth_token(user.did, "session-1", Token.refresh())

    assert :ok = Accounts.reset_password(user, "the new password")

    assert Repo.reload!(access).revoked
    assert Repo.reload!(refresh).revoked
  end

  test "another account's tokens are nobody else's to revoke", %{user: user} do
    other_handle =
      "other" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"

    {:ok, other} = Accounts.create_account(other_handle, "other@localhost", @password)
    token = oauth_token(other.did, "session-2", Token.access())

    assert :ok = Accounts.reset_password(user, "the new password")

    refute Repo.reload!(token).revoked
  end

  defp oauth_token(did, session_id, kind) do
    %Token{
      token_hash: Token.hash(kind <> "-" <> session_id),
      jti: "jti-" <> kind <> "-" <> session_id,
      kind: kind,
      did: did,
      client_id: "https://example.client/client-metadata.json",
      scope: "atproto",
      dpop_jkt: "jkt-" <> session_id,
      session_id: session_id,
      expires_at: DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:second)
    }
    |> Repo.insert!()
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
