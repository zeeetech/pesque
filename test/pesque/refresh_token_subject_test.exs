defmodule Pesque.Accounts.RefreshTokenSubjectTest do
  @moduledoc """
  The refresh token's subject against the row it belongs to.

  rotate_session/1 looks the row up by jti and then goes on to the subject in
  the token. Those two can never disagree today: this server signed the token
  and the jti is unique, so the comparison decides nothing now. It is the check
  for the day that stops being true, and it is also what makes the did index
  from migration 010 worth having, since otherwise nothing ever reads that
  column.

  The mismatch below is therefore a manufactured one, and it says so: the row
  is rewritten to name another account, which is what the check has to refuse.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.RefreshToken
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)

    alice = insert_account("alice")
    bob = insert_account("bob")

    {:ok, session} = Accounts.issue_session(alice.did)

    %{alice: alice, bob: bob, refresh_jwt: session.refresh_jwt}
  end

  test "the stored row names the account the token names", ctx do
    row = live_row(ctx)

    assert row.did == claims(ctx)["sub"]
    assert row.did == ctx.alice.did
  end

  test "a live token whose subject matches rotates", ctx do
    assert {:ok, session, user} = Accounts.rotate_session(ctx.refresh_jwt)
    assert user.did == ctx.alice.did
    assert session.access_jwt
    assert session.refresh_jwt
  end

  test "a row naming another account is refused", ctx do
    # The only way to get here: the row is written by this server from the
    # subject it issued, so rewriting it is the manufactured case the check is
    # for, not a state a client can reach.
    Repo.update_all(
      from(t in RefreshToken, where: t.did == ^ctx.alice.did),
      set: [did: ctx.bob.did]
    )

    assert {:error, :invalid_token} = Accounts.rotate_session(ctx.refresh_jwt)

    # Refused before the revoke, so a mismatch does not spend the row either.
    refute live_row(ctx).revoked
  end

  test "a revoked row naming another account is refused too", ctx do
    Repo.update_all(
      from(t in RefreshToken, where: t.did == ^ctx.alice.did),
      set: [did: ctx.bob.did, revoked: true]
    )

    assert {:error, :invalid_token} = Accounts.rotate_session(ctx.refresh_jwt)
  end

  # bob's session rotating to bob is the control: the same code path, a row
  # that agrees with its own token, so a failure above is the comparison and not
  # something else in the chain.
  test "the comparison does not refuse a row that agrees", ctx do
    {:ok, bob_session} = Accounts.issue_session(ctx.bob.did)

    assert {:ok, _session, user} = Accounts.rotate_session(bob_session.refresh_jwt)
    assert user.did == ctx.bob.did
  end

  defp claims(ctx) do
    assert {:ok, claims} =
             Pesque.Token.verify(ctx.refresh_jwt, Pesque.Secret.get(), "com.atproto.refresh")

    claims
  end

  defp live_row(ctx) do
    [row] = Repo.all(from t in RefreshToken, where: t.jti_hash == ^hash(ctx))
    row
  end

  defp hash(ctx), do: RefreshToken.hash_jti(claims(ctx)["jti"])

  defp insert_account(name) do
    {:ok, user} = Accounts.create_account(name <> ".localhost", name <> "@localhost", @password)
    user
  end

  defp put_mode(mode) do
    previous = Application.get_env(:pesque, :mode)

    on_exit(fn -> Application.put_env(:pesque, :mode, previous) end)

    Application.put_env(:pesque, :mode, mode)
  end
end
