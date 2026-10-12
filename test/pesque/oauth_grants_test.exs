defmodule Pesque.OAuth.GrantsTest do
  @moduledoc """
  The grant set a scope string carries, and the three queries the plug and
  the session controller ask of it.

  The atproto rule is the one to watch: it is the whole account only when it
  is the whole string, because it is the one scope every client must carry
  and the only thing a consent-page uncheck has to be able to narrow.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Grants
  alias Pesque.OAuth.Permission

  test "a bare atproto string is the full grant" do
    assert [%Permission{resource: :atproto}] = Grants.parse("atproto")
  end

  test "atproto beside another scope is the marker, and the other scope is the grant" do
    assert [%Permission{resource: :transition_generic}] =
             Grants.parse("atproto transition:generic")

    assert [%Permission{resource: :transition_email}] = Grants.parse("atproto transition:email")

    assert [%Permission{resource: :repo, collection: ["app.bsky.feed.post"]}] =
             Grants.parse("atproto repo:app.bsky.feed.post")
  end

  test "a string with several scopes carries one grant per scope, order preserved" do
    grants = Grants.parse("atproto transition:generic transition:chat.bsky")

    assert [%Permission{resource: :transition_generic}, %Permission{resource: :transition_chat}] =
             grants
  end

  test "an unparseable or ungrantable scope contributes nothing, never a failure" do
    assert Grants.parse("atproto transition:generic nope:nope") ==
             [%Permission{resource: :transition_generic}]

    assert Grants.parse("atproto include:app.example.authFull") == []
    assert Grants.parse("") == []
    assert Grants.parse(nil) == []
    assert Grants.parse("   ") == []
  end

  test "duplicates collapse" do
    assert Grants.parse("atproto atproto") == [%Permission{resource: :atproto}]
  end

  test "the email is visible to atproto, to the email transition, and to account:email" do
    assert Grants.email_visible?(Grants.parse("atproto"))
    assert Grants.email_visible?(Grants.parse("atproto transition:email"))
    assert Grants.email_visible?(Grants.parse("atproto account:email"))
    assert Grants.email_visible?(Grants.parse("atproto account:email?action=manage"))

    # The compat narrowing: a generic token is an app password, and an app
    # password never saw the email.
    refute Grants.email_visible?(Grants.parse("atproto transition:generic"))
    refute Grants.email_visible?(Grants.parse("atproto repo:app.bsky.feed.post"))
    refute Grants.email_visible?(Grants.parse(""))
  end

  test "preferences answer to atproto, to the generic transition, and to a named rpc" do
    for grants <- [
          Grants.parse("atproto"),
          Grants.parse("atproto transition:generic"),
          Grants.parse(
            "atproto rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23appview"
          )
        ] do
      assert Grants.preferences?(grants, :get), inspect(grants)
    end

    for grants <- [
          Grants.parse("atproto transition:generic"),
          Grants.parse(
            "atproto rpc:app.bsky.actor.putPreferences?aud=did:web:api.bsky.app%23appview"
          )
        ] do
      assert Grants.preferences?(grants, :put), inspect(grants)
    end

    # A named rpc grant covers its one method, not the other one.
    refute Grants.preferences?(
             Grants.parse(
               "atproto rpc:app.bsky.actor.getPreferences?aud=did:web:api.bsky.app%23appview"
             ),
             :put
           )

    refute Grants.preferences?(Grants.parse("atproto repo:app.bsky.feed.post"), :get)
  end
end
