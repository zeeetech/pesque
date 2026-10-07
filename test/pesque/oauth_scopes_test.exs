defmodule Pesque.OAuth.ScopesTest do
  @moduledoc """
  Scope validation, which is the last place a client finds out it asked for
  something this server will not do.

  The rule the profile sets is that `atproto` is required, that `openid` is
  incompatible, and that a scope this server does not implement is an error
  rather than a token for something nothing enforces.
  """

  use ExUnit.Case, async: true

  alias Pesque.OAuth.Scopes

  test "the two scopes this server grants are the two it advertises" do
    assert Scopes.supported() == ["atproto", "transition:generic"]
  end

  test "a request naming supported scopes is accepted and normalized" do
    assert {:ok, "atproto transition:generic"} =
             Scopes.validate("atproto transition:generic")

    assert {:ok, "atproto"} = Scopes.validate("atproto")
    assert {:ok, "atproto"} = Scopes.validate("atproto  atproto")
  end

  test "a request without atproto is refused" do
    assert {:error, :missing_atproto_scope} = Scopes.validate("transition:generic")
  end

  test "openid is refused rather than ignored" do
    assert {:error, :openid_not_supported} = Scopes.validate("atproto openid")
  end

  test "a scope this server does not grant names itself in the error" do
    assert {:error, {:unsupported_scope, "transition:chat.bsky"}} =
             Scopes.validate("atproto transition:chat.bsky")

    assert {:error, {:unsupported_scope, "atproto:write"}} =
             Scopes.validate("atproto:write")
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
