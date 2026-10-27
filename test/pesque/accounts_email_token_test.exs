defmodule Pesque.Accounts.EmailTokenTest do
  @moduledoc """
  The email-confirmation and password-reset codes: what a code confirms, that it
  is single use and expiring, and that neither is answered to a caller that has
  not proven the account.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.Token
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:multi)

    handle = "email" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  describe "email confirmation" do
    test "a code confirms the account's email", %{user: user} do
      assert is_nil(Accounts.get_user(user.did).email_confirmed_at)

      {:ok, %{token: token}} = Accounts.request_email_confirmation(user)

      assert :ok = Accounts.confirm_email(user, user.email, token)
      assert %DateTime{} = Accounts.get_user(user.did).email_confirmed_at
    end

    test "the code is stored hashed and bound to the address", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_email_confirmation(user)

      assert %Token{token_hash: hash, email: email} =
               Repo.one!(from t in Token, where: t.did == ^user.did and t.purpose == :email)

      assert hash == Token.hash_token(token)
      refute hash == token
      assert email == user.email
    end

    test "a code is single use", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_email_confirmation(user)

      assert :ok = Accounts.confirm_email(user, user.email, token)
      assert {:error, :invalid_token} = Accounts.confirm_email(user, user.email, token)
    end

    test "an email that is not the account's is refused before the code is spent",
         %{user: user} do
      {:ok, %{token: token}} = Accounts.request_email_confirmation(user)

      assert {:error, :invalid_email} = Accounts.confirm_email(user, "someone@else", token)

      # The refusal did not spend the code: it is still good for the address it
      # names.
      assert :ok = Accounts.confirm_email(user, user.email, token)
    end

    test "an expired code is refused", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_email_confirmation(user)
      expire_all(:email)

      assert {:error, :expired_token} = Accounts.confirm_email(user, user.email, token)
    end

    test "an unknown code is refused", %{user: user} do
      assert {:error, :invalid_token} = Accounts.confirm_email(user, user.email, "nope")
    end

    test "a second request issues a second live code", %{user: user} do
      {:ok, %{token: first}} = Accounts.request_email_confirmation(user)
      {:ok, %{token: second}} = Accounts.request_email_confirmation(user)

      assert :ok = Accounts.confirm_email(user, user.email, first)
      assert :ok = Accounts.confirm_email(user, user.email, second)
    end
  end

  describe "password reset" do
    test "a code from the account's email resets the password", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)

      assert :ok = Accounts.reset_password_with_token(token, "the new password")
      assert {:ok, _user} = Accounts.verify_login(user.handle, "the new password")
      assert :error = Accounts.verify_login(user.handle, @password)
    end

    test "an address with no account answers :ok and mints nothing", %{user: _user} do
      assert :ok = Accounts.request_password_reset("nobody@localhost")
      assert Repo.aggregate(from(t in Token, where: t.purpose == :reset_password), :count) == 0
    end

    test "the code is stored hashed, never in the clear", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)

      assert %Token{token_hash: hash} =
               Repo.one!(
                 from t in Token, where: t.did == ^user.did and t.purpose == :reset_password
               )

      assert hash == Token.hash_token(token)
      refute hash == token
    end

    test "a code is single use", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)

      assert :ok = Accounts.reset_password_with_token(token, "the new password")
      assert {:error, :invalid_token} = Accounts.reset_password_with_token(token, "another try")
    end

    test "a reset revokes the account's sessions", %{user: user} do
      {:ok, session} = Accounts.issue_session(user.did)
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)

      assert :ok = Accounts.reset_password_with_token(token, "the new password")
      assert {:error, :invalid_token} = Accounts.rotate_session(session.refresh_jwt)
    end

    test "an expired code is refused and nothing changes", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)
      expire_all(:reset_password)

      assert {:error, :expired_token} =
               Accounts.reset_password_with_token(token, "the new password")

      assert {:ok, _user} = Accounts.verify_login(user.handle, @password)
    end

    test "a too-short password is refused and the code is not spent", %{user: user} do
      {:ok, %{token: token}} = Accounts.request_password_reset(user.email)

      assert {:error, :password_too_short} = Accounts.reset_password_with_token(token, "short")

      # Refused before the spend, so the code still resets.
      assert :ok = Accounts.reset_password_with_token(token, "the new password")
    end

    test "a bad code is refused and changes nothing", %{user: user} do
      assert {:error, :invalid_token} =
               Accounts.reset_password_with_token("nope", "the new password")

      assert {:ok, _user} = Accounts.verify_login(user.handle, @password)
    end
  end

  describe "email update" do
    test "an unconfirmed address moves with no code", %{user: user} do
      assert {:ok, %{token_required: false}} = Accounts.request_email_update(user)

      assert {:ok, updated} = Accounts.update_email(user, "new@localhost", nil)
      assert updated.email == "new@localhost"
      assert is_nil(updated.email_confirmed_at)
    end

    test "a confirmed address needs a code minted to it", %{user: user} do
      confirmed = confirm(user)
      {:ok, %{token_required: true, token: token}} = Accounts.request_email_update(confirmed)

      assert {:error, :token_required} = Accounts.update_email(confirmed, "new@localhost", nil)

      assert {:ok, updated} = Accounts.update_email(confirmed, "new@localhost", token)
      assert updated.email == "new@localhost"
      # The new address is unconfirmed: it is only proven by its own code.
      assert is_nil(updated.email_confirmed_at)
    end

    test "the code is spent by the move", %{user: user} do
      confirmed = confirm(user)
      {:ok, %{token: token}} = Accounts.request_email_update(confirmed)

      assert {:ok, _updated} = Accounts.update_email(confirmed, "new@localhost", token)

      spent =
        Repo.one!(from t in Token, where: t.token_hash == ^Token.hash_token(token))

      refute is_nil(spent.used_at)
    end

    test "a code already spent is refused and nothing moves", %{user: user} do
      confirmed = confirm(user)
      {:ok, %{token: token}} = Accounts.request_email_update(confirmed)

      # Spend it on the confirm path, which leaves the address confirmed, so a
      # second use still has a code to check.
      assert :ok = Accounts.confirm_email(confirmed, confirmed.email, token)

      assert {:error, :invalid_token} = Accounts.update_email(confirmed, "new@localhost", token)
      assert Accounts.get_user(user.did).email == confirmed.email
    end

    test "an expired code is refused", %{user: user} do
      confirmed = confirm(user)
      {:ok, %{token: token}} = Accounts.request_email_update(confirmed)
      expire_all(:email)

      assert {:error, :expired_token} = Accounts.update_email(confirmed, "new@localhost", token)
    end

    test "another account's email is refused", %{user: user} do
      bob = second_account()
      assert {:error, :email_taken} = Accounts.update_email(user, bob.email, nil)
    end

    test "another account's handle cannot be taken as an email", %{user: user} do
      bob = second_account()
      assert {:error, :email_taken} = Accounts.update_email(user, bob.handle, nil)
    end
  end

  defp confirm(user) do
    {:ok, %{token: token}} = Accounts.request_email_confirmation(user)
    :ok = Accounts.confirm_email(user, user.email, token)
    Accounts.get_user(user.did)
  end

  defp second_account do
    handle = "other" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"
    {:ok, user} = Accounts.create_account(handle, "bob@localhost", @password)
    user
  end

  defp expire_all(purpose) do
    Repo.update_all(from(t in Token, where: t.purpose == ^purpose),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)
    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)
    Application.put_env(:pesque, :mode, mode)
  end
end
