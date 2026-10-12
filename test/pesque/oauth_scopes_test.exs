defmodule Pesque.OAuth.ScopesTest do
  @moduledoc """
  Scope validation, which is the last place a client finds out it asked for
  something this server will not do.

  The rule the profile sets is that `atproto` is required, that `openid` is
  incompatible, and that a scope this server does not grant is an error
  rather than a token for something nothing enforces. The offending scope is
  named before anything else is checked.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Scopes

  test "the scopes this server grants are the ones it advertises" do
    assert Scopes.supported() == [
             "atproto",
             "transition:generic",
             "transition:chat.bsky",
             "transition:email"
           ]
  end

  test "a request naming supported scopes is accepted and normalized" do
    assert {:ok, "atproto transition:generic"} =
             Scopes.validate("atproto transition:generic")

    assert {:ok, "atproto transition:generic transition:chat.bsky"} =
             Scopes.validate("atproto transition:generic transition:chat.bsky")

    assert {:ok, "atproto transition:email"} = Scopes.validate("atproto transition:email")
    assert {:ok, "atproto"} = Scopes.validate("atproto")
    assert {:ok, "atproto"} = Scopes.validate("atproto  atproto")
  end

  test "granular permission strings are accepted" do
    assert {:ok, "atproto repo:app.bsky.feed.post?action=create"} =
             Scopes.validate("atproto repo:app.bsky.feed.post?action=create")

    assert {:ok, "atproto blob:image/*"} = Scopes.validate("atproto blob:image/*")

    assert {:ok, "atproto rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23appview"} =
             Scopes.validate(
               "atproto rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:api.bsky.app%23appview"
             )

    assert {:ok, "atproto account:email"} = Scopes.validate("atproto account:email")
    assert {:ok, "atproto identity:handle"} = Scopes.validate("atproto identity:handle")
  end

  test "a request without atproto is refused" do
    assert {:error, :missing_atproto_scope} = Scopes.validate("transition:generic")
    assert {:error, :missing_atproto_scope} = Scopes.validate("repo:app.bsky.feed.post")
  end

  test "openid is refused rather than ignored" do
    assert {:error, :openid_not_supported} = Scopes.validate("atproto openid")

    # The refusal is openid's, even when something else is wrong too.
    assert {:error, :openid_not_supported} = Scopes.validate("openid")
    assert {:error, :openid_not_supported} = Scopes.validate("openid transition:generic")
  end

  test "an include of a set this server cannot resolve names the set" do
    assert {:error, {:unresolved_permission_set, "app.bsky.authFull"}} =
             Scopes.validate("atproto include:app.bsky.authFull")
  end

  test "an include of a set this server resolves is accepted" do
    assert {:ok, "atproto include:app.bsky.authFullApp?aud=did:web:api.bsky.app%23appview"} =
             Scopes.validate(
               "atproto include:app.bsky.authFullApp?aud=did:web:api.bsky.app%23appview"
             )
  end

  test "a malformed include is refused as invalid, like any unparseable scope" do
    assert {:error, {:invalid_scope, "include:not-an-nsid"}} =
             Scopes.validate("atproto include:not-an-nsid")
  end

  test "a scope that does not parse is refused as invalid, with the string named" do
    assert {:error, {:invalid_scope, "atproto:write"}} = Scopes.validate("atproto:write")
    assert {:error, {:invalid_scope, "nonsense"}} = Scopes.validate("atproto nonsense")

    assert {:error, {:invalid_scope, "repo:com.example.*"}} =
             Scopes.validate("atproto repo:com.example.*")

    assert {:error, {:invalid_scope, "rpc:app.example.get"}} =
             Scopes.validate("atproto rpc:app.example.get")
  end

  test "the chat scope requires the generic one beside it" do
    assert {:error, :chat_requires_generic} =
             Scopes.validate("atproto transition:chat.bsky")

    assert {:ok, "atproto transition:chat.bsky transition:generic"} =
             Scopes.validate("atproto transition:chat.bsky transition:generic")
  end

  test "the offending scope is named before the missing atproto is" do
    assert {:error, {:invalid_scope, "nonsense"}} = Scopes.validate("nonsense")

    assert {:error, {:unresolved_permission_set, "app.bsky.authFull"}} =
             Scopes.validate("include:app.bsky.authFull")
  end

  test "a missing or empty scope is refused" do
    assert {:error, :missing_scope} = Scopes.validate(nil)
    assert {:error, :missing_scope} = Scopes.validate("")
    assert {:error, :missing_scope} = Scopes.validate("   ")
  end

  test "a scope that is not a string is refused" do
    assert {:error, :missing_scope} = Scopes.validate(["atproto"])
    assert {:error, :missing_scope} = Scopes.validate(42)
  end
end
