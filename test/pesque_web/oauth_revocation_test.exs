defmodule PesqueWeb.OAuth.RevocationTest do
  @moduledoc """
  Revocation and session lifetime, which is what a user reaches for when they
  mean "get rid of that app".

  Two things are asserted beyond the endpoint answering: that a revocation
  actually stops the token working, and that the database holds no plaintext
  credential. The second is the reason every token column is a hash, and it is
  worth a test because nothing else fails if that regresses.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.OAuth
  alias Pesque.OAuth.Token
  alias Pesque.Repo
  alias PesqueWeb.OAuthCase, as: Client

  setup do
    %{user: create_account("alice"), key: Client.dpop_key()}
  end

  test "revoking an access token stops it verifying", ctx do
    granted = Client.approve(ctx.user, ctx.key)
    tokens = code_exchange(ctx, granted)

    assert {:ok, _claims} = OAuth.verify_access_token(tokens["access_token"])

    assert Client.revoke(ctx.key, tokens["access_token"], granted.nonce).status == 200

    assert {:error, :invalid_token} = OAuth.verify_access_token(tokens["access_token"])
  end

  test "revoking a refresh token revokes the access token beside it", ctx do
    granted = Client.approve(ctx.user, ctx.key)
    tokens = code_exchange(ctx, granted)

    Client.revoke(ctx.key, tokens["refresh_token"], granted.nonce)

    assert {:error, :invalid_token} = OAuth.verify_access_token(tokens["access_token"])
  end

  test "revoking one session leaves another alone", ctx do
    first = Client.approve(ctx.user, ctx.key)
    first_tokens = code_exchange(ctx, first)

    # A second session is a second push and a second DPoP key: one client
    # software holding two sessions is two sessions, and revoking one must not
    # take the other with it.
    second_key = Client.dpop_key()
    second = Client.approve(ctx.user, second_key)
    second_tokens = tokens_with(second, second_key)

    Client.revoke(ctx.key, first_tokens["refresh_token"], first.nonce)

    assert {:error, :invalid_token} = OAuth.verify_access_token(first_tokens["access_token"])
    assert {:ok, _claims} = OAuth.verify_access_token(second_tokens["access_token"])
  end

  test "a token response is never cacheable", ctx do
    granted = Client.approve(ctx.user, ctx.key)
    conn = exchange_conn(ctx, granted)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "an access token response carries the DPoP nonce a client needs next", ctx do
    granted = Client.approve(ctx.user, ctx.key)
    conn = exchange_conn(ctx, granted)

    assert is_binary(Client.nonce_from(conn))
  end

  test "nothing in the table is the token itself", ctx do
    granted = Client.approve(ctx.user, ctx.key)
    tokens = code_exchange(ctx, granted)

    rows = Repo.all(Token)

    assert length(rows) == 2

    # Nothing in either column is either token: the hash is what a lookup uses,
    # and the access token's jti is the one its signed JWT carries, which is not
    # the token.
    for row <- rows do
      refute row.token_hash == tokens["access_token"]
      refute row.token_hash == tokens["refresh_token"]
      refute row.jti == tokens["access_token"]
      refute row.jti == tokens["refresh_token"]
    end

    [access] = Enum.filter(rows, &(&1.kind == "access"))
    assert {:ok, claims} = OAuth.verify_access_token(tokens["access_token"])
    assert claims["jti"] == access.jti
  end

  test "no code or request_uri reaches the database in the clear", ctx do
    pushed = Client.par(ctx.key)
    granted = Client.approve(ctx.user, ctx.key)

    # Two requests: the one this test pushed and the one approve/2 pushed.
    assert [_pushed, approved] = Repo.all(Pesque.OAuth.Request)

    refute approved.request_uri_hash == pushed.request_uri
    refute approved.request_uri_hash == granted.request_uri
    refute approved.code_hash == granted.code
    assert approved.code_hash
  end

  defp exchange_conn(ctx, granted), do: exchange_conn_for(granted, ctx.key)

  defp code_exchange(ctx, granted), do: ctx |> exchange_conn(granted) |> Client.json()

  defp exchange_conn_for(granted, key) do
    params = %{
      "grant_type" => "authorization_code",
      "client_id" => granted.client_id,
      "code" => granted.code,
      "code_verifier" => granted.verifier,
      "redirect_uri" => granted.redirect_uri
    }

    Client.exchange(key, params, nonce: granted.nonce)
  end

  defp tokens_with(granted, key), do: granted |> exchange_conn_for(key) |> Client.json()
end
