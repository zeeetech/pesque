defmodule PesqueWeb.SessionPasswordShapeTest do
  @moduledoc """
  The shape of a login body, before anything asks the database.

  Argon2's NIF raises ArgumentError on a password that is not a binary, and it
  only reaches the NIF for an identifier a row names: an unknown handle takes
  the no_user_verify branch and answers 401, while a real handle reached
  verify_pass and answered 500. Two status codes for the same malformed body
  is an unauthenticated answer to "is this handle registered", on a server
  whose registration is closed precisely so that list is not public.

  So these are HTTP tests, not Accounts tests. The unit level cannot see the
  oracle: it is the status code on the wire that carries it.
  """

  use PesqueWeb.ConnCase, async: false

  @session_path "/xrpc/com.atproto.server.createSession"
  @account_path "/xrpc/com.atproto.server.createAccount"
  @password "hunter2hunter2"

  # Anything that is not a string, one per JSON type the parser produces.
  @not_strings [[], %{"a" => 1}, 123, 1.5, true, nil]

  setup do
    alice = create_account("alice")

    %{alice: alice, token: token(alice)}
  end

  test "a non-string password is 400 on createSession, known handle or not", ctx do
    for password <- @not_strings do
      unknown = post_session("nosuch", password)
      known = post_session(ctx.alice.handle, password)

      assert unknown.status == 400, "unknown handle answered #{unknown.status}"
      assert known.status == 400, "known handle answered #{known.status}"

      assert JSON.decode!(unknown.resp_body)["error"] == "InvalidRequest"
      assert JSON.decode!(known.resp_body)["error"] == "InvalidRequest"
    end
  end

  test "the two answers are identical, not merely both 400", ctx do
    for password <- @not_strings do
      unknown = JSON.decode!(post_session("nosuch", password).resp_body)
      known = JSON.decode!(post_session(ctx.alice.handle, password).resp_body)

      assert unknown == known
    end
  end

  test "a non-string password is 400 on createAccount too" do
    for password <- @not_strings do
      conn =
        xrpc_post(
          @account_path,
          %{
            "handle" => unique("bob") <> ".localhost",
            "email" => unique("bob") <> "@localhost",
            "password" => password
          },
          nil
        )

      assert conn.status == 400, "createAccount answered #{conn.status}"
      assert JSON.decode!(conn.resp_body)["error"] == "InvalidRequest"
    end

    assert Accounts.get_user("did:web:nobody:user:bob") == nil
  end

  test "a missing password is still 400, on both", ctx do
    assert xrpc_post(@session_path, %{"identifier" => ctx.alice.handle}, nil).status == 400

    conn =
      xrpc_post(
        @account_path,
        %{"handle" => unique("bob") <> ".localhost", "email" => unique("bob") <> "@localhost"},
        nil
      )

    assert conn.status == 400
  end

  # The oracle only existed because the raise was a 500. A wrong password on a
  # real account is a 401 and must stay one, or the fix has simply moved the
  # boundary.
  test "a string password that is wrong is still 401", ctx do
    conn = post_session(ctx.alice.handle, "not-the-password")

    assert conn.status == 401
    assert JSON.decode!(conn.resp_body)["error"] == "AuthenticationRequired"
  end

  test "the right password still logs in", ctx do
    conn = post_session(ctx.alice.handle, @password)

    assert conn.status == 200

    body = JSON.decode!(conn.resp_body)
    assert body["did"] == ctx.alice.did
    assert body["accessJwt"]
  end

  defp post_session(identifier, password) do
    xrpc_post(@session_path, %{"identifier" => identifier, "password" => password}, nil)
  end
end
