defmodule Pesque.Accounts.AppPasswordTest do
  @moduledoc """
  The app-password credential lifecycle through the domain: create (the
  password answered exactly once), list, revoke (the credential and its
  sessions together), and the createSession credential check that widens to
  them and nothing else.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Accounts.AppPassword
  alias Pesque.OAuth.Grants
  alias Pesque.OAuth.Permission

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()

    # multi so the account gets a handle: under single the
    # seeded server row has no handle and every account compares as taken.
    put_mode(:multi)

    handle =
      "appword" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".localhost"

    {:ok, user} = Accounts.create_account(handle, "alice@localhost", @password)

    %{user: user}
  end

  test "create answers the password once, and the row keeps only its hash", %{user: user} do
    {:ok, app_password} = Accounts.create_app_password(user, "my-app", false)

    assert app_password.name == "my-app"
    assert app_password.privileged == false
    assert %DateTime{} = app_password.created_at
    assert app_password.password =~ ~r/\A[a-z2-7]{4}(-[a-z2-7]{4}){3}\z/

    row = fetch_row(user, "my-app")
    assert row.privileged == false
    assert row.password_hash == AppPassword.hash_password(user.did, app_password.password)
  end

  test "privileged round-trips", %{user: user} do
    {:ok, _app_password} = Accounts.create_app_password(user, "trusted", true)

    assert fetch_row(user, "trusted").privileged == true
  end

  test "a name the account already uses is refused, and free again after a revoke", %{user: user} do
    assert {:ok, _} = Accounts.create_app_password(user, "twice", false)

    assert Accounts.create_app_password(user, "twice", false) ==
             {:error, :app_password_name_taken}

    assert :ok = Accounts.revoke_app_password(user, "twice")

    {:ok, second} = Accounts.create_app_password(user, "twice", true)
    assert second.privileged == true
  end

  test "an empty or non-binary name is refused as name_required", %{user: user} do
    assert Accounts.create_app_password(user, "", false) == {:error, :app_password_name_required}
    assert Accounts.create_app_password(user, nil, false) == {:error, :app_password_name_required}
    assert Accounts.create_app_password(user, 42, false) == {:error, :app_password_name_required}
  end

  test "list answers newest first", %{user: user} do
    {:ok, first} = Accounts.create_app_password(user, "first", false)
    {:ok, second} = Accounts.create_app_password(user, "second", false)

    names = for row <- Accounts.list_app_passwords(user.did), do: row.name
    assert names == [second.name, first.name]
  end

  test "revoke deletes the credential and every session opened with it, and only those", %{
    user: user
  } do
    {:ok, doomed} = Accounts.create_app_password(user, "doomed", false)
    {:ok, kept} = Accounts.create_app_password(user, "kept", false)

    {:ok, doomed_session} =
      Accounts.issue_session(user.did, app_password: fetch_row(user, doomed.name))

    {:ok, kept_session} =
      Accounts.issue_session(user.did, app_password: fetch_row(user, kept.name))

    {:ok, password_session} = Accounts.issue_session(user.did)

    assert :ok = Accounts.revoke_app_password(user, doomed.name)
    assert for(row <- Accounts.list_app_passwords(user.did), do: row.name) == [kept.name]

    assert {:error, :invalid_token} = Accounts.rotate_session(doomed_session.refresh_jwt)
    assert {:ok, _, _} = Accounts.rotate_session(kept_session.refresh_jwt)
    assert {:ok, _, _} = Accounts.rotate_session(password_session.refresh_jwt)

    # Idempotent: the state the caller asked for is already the state.
    assert :ok = Accounts.revoke_app_password(user, doomed.name)
  end

  test "revoke with a non-binary name answers name_required", %{user: user} do
    assert Accounts.revoke_app_password(user, nil) == {:error, :app_password_name_required}
  end

  describe "verify_session_credentials" do
    test "the account password answers {:ok, user, nil}", %{user: user} do
      assert {:ok, ^user, nil} = Accounts.verify_session_credentials(user.handle, @password)
    end

    test "an app password answers {:ok, user, the credential}", %{user: user} do
      {:ok, app_password} = Accounts.create_app_password(user, "login-app", true)

      assert {:ok, ^user, %AppPassword{name: "login-app", privileged: true}} =
               Accounts.verify_session_credentials(user.handle, app_password.password)
    end

    test "a wrong password and an unknown identifier answer :error", %{user: user} do
      {:ok, app_password} = Accounts.create_app_password(user, "login-app", false)

      assert :error = Accounts.verify_session_credentials(user.handle, "not-any-password")

      assert :error =
               Accounts.verify_session_credentials(user.handle, app_password.password <> "x")

      assert :error = Accounts.verify_session_credentials("nobody.localhost", @password)
    end

    # The escalation pin: verify_login/2 keeps meaning the account password,
    # because the OAuth authorize page calls it. An app password that logged
    # in there would approve a full atproto token, which is the app-password
    # reduction undone through the front door.
    test "an app password is refused by verify_login", %{user: user} do
      {:ok, app_password} = Accounts.create_app_password(user, "login-app", true)

      assert {:ok, _user} = Accounts.verify_login(user.handle, @password)
      assert :error = Accounts.verify_login(user.handle, app_password.password)
    end
  end

  test "issue_session carries the tier in the scope claim and names the credential on the row", %{
    user: user
  } do
    {:ok, app_password} = Accounts.create_app_password(user, "tier-app", false)
    {:ok, privileged} = Accounts.create_app_password(user, "tier-priv", true)
    {:ok, plain} = Accounts.issue_session(user.did)

    assert scope_claim(plain.access_jwt) == "com.atproto.access"

    {:ok, session} =
      Accounts.issue_session(user.did, app_password: fetch_row(user, app_password.name))

    assert scope_claim(session.access_jwt) == "com.atproto.appPass"

    {:ok, priv_session} =
      Accounts.issue_session(user.did, app_password: fetch_row(user, privileged.name))

    assert scope_claim(priv_session.access_jwt) == "com.atproto.appPassPrivileged"

    # The grants the non-privileged tier computes to are exactly
    # transition:generic; the privileged one is the full grant, the same list
    # a password-login session carries.
    assert Grants.from_session_scope(scope_claim(session.access_jwt)) ==
             Grants.parse("atproto transition:generic")

    assert Grants.from_session_scope(scope_claim(priv_session.access_jwt)) == [
             %Permission{resource: :atproto}
           ]

    # The refresh row names the credential, so revocation can find it.
    assert refresh_row(session.refresh_jwt).app_password_name == "tier-app"
    assert refresh_row(plain.refresh_jwt).app_password_name == nil
  end

  test "rotation re-reads the credential and keeps the tier", %{user: user} do
    {:ok, _app_password} = Accounts.create_app_password(user, "rotate-app", false)
    {:ok, session} = Accounts.issue_session(user.did, app_password: fetch_row(user, "rotate-app"))

    assert {:ok, rotated, _user} = Accounts.rotate_session(session.refresh_jwt)
    assert scope_claim(rotated.access_jwt) == "com.atproto.appPass"
  end

  test "reset_password keeps the rows and kills their sessions", %{user: user} do
    {:ok, app_password} = Accounts.create_app_password(user, "survivor", false)
    {:ok, session} = Accounts.issue_session(user.did, app_password: fetch_row(user, "survivor"))

    assert :ok = Accounts.reset_password(user, "the new password")

    # The credential survives a reset: the reset recovers the account
    # password, and the per-app recovery path is revoking by name.
    assert for(row <- Accounts.list_app_passwords(user.did), do: row.name) == ["survivor"]

    assert {:error, :invalid_token} = Accounts.rotate_session(session.refresh_jwt)

    # The app password itself still logs in, on the surviving account.
    assert {:ok, _user, %AppPassword{}} =
             Accounts.verify_session_credentials(user.handle, app_password.password)
  end

  test "delete_account purges the rows", %{user: user} do
    {:ok, _app_password} = Accounts.create_app_password(user, "gone", false)

    {:ok, %{token: token}} = Accounts.request_account_delete(user)
    assert {:ok, _did} = Accounts.delete_account(user, user.did, @password, token)

    assert Accounts.list_app_passwords(user.did) == []
  end

  # helpers

  defp fetch_row(user, name) do
    case Enum.find(Accounts.list_app_passwords(user.did), &(&1.name == name)) do
      %AppPassword{} = row -> row
      nil -> raise "no app password named #{name} for #{user.did}"
    end
  end

  defp scope_claim(jwt) do
    [_header, payload, _sig] = String.split(jwt, ".")
    %{"scope" => scope} = payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
    scope
  end

  defp refresh_row(refresh_jwt) do
    {:ok, claims} =
      Pesque.Token.verify(refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh")

    Pesque.Repo.get_by!(Accounts.RefreshToken,
      jti_hash: Accounts.RefreshToken.hash_jti(claims["jti"])
    )
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
