defmodule Pesque.TokenTest do
  use ExUnit.Case, async: true

  alias Pesque.Token

  @secret "test-server-secret"

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "scope" => "com.atproto.access",
        "sub" => "did:web:localhost",
        "iat" => now,
        "exp" => now + 3600
      },
      overrides
    )
  end

  test "sign then verify round trips the claims" do
    token = Token.sign(claims(), @secret)

    assert {:ok, verified} = Token.verify(token, @secret, "com.atproto.access")
    assert verified == claims()
  end

  test "verify rejects a token signed with a different secret" do
    token = Token.sign(claims(), @secret)

    assert Token.verify(token, "another-secret", "com.atproto.access") == {:error, :invalid_token}
  end

  test "verify rejects an expired token" do
    now = System.system_time(:second)
    token = Token.sign(claims(%{"exp" => now - 1}), @secret)

    assert Token.verify(token, @secret, "com.atproto.access") == {:error, :invalid_token}
  end

  test "verify rejects a token with no sub claim" do
    now = System.system_time(:second)

    token =
      Token.sign(%{"scope" => "com.atproto.access", "iat" => now, "exp" => now + 3600}, @secret)

    assert Token.verify(token, @secret, "com.atproto.access") == {:error, :invalid_token}
  end

  test "verify rejects a wrong scope" do
    token = Token.sign(claims(), @secret)

    assert Token.verify(token, @secret, "com.atproto.refresh") == {:error, :invalid_token}
  end

  test "verify rejects a tampered payload" do
    [header, payload, sig] = String.split(Token.sign(claims(), @secret), ".")
    size = byte_size(payload)
    index = div(size, 2)
    before = binary_part(payload, 0, index)
    char = binary_part(payload, index, 1)
    rest = binary_part(payload, index + 1, size - index - 1)
    replacement = if char == "A", do: "B", else: "A"
    tampered = Enum.join([header, before <> replacement <> rest, sig], ".")

    assert length(String.split(tampered, ".")) == 3
    assert Token.verify(tampered, @secret, "com.atproto.access") == {:error, :invalid_token}
  end

  test "verify rejects a mangled signature segment" do
    [header, payload, _sig] = String.split(Token.sign(claims(), @secret), ".")
    tampered = Enum.join([header, payload, "bm90LWEtc2lnbmF0dXJl"], ".")

    assert Token.verify(tampered, @secret, "com.atproto.access") == {:error, :invalid_token}
  end

  test "ttls are the documented values" do
    assert Token.access_ttl_seconds() == 7200
    assert Token.refresh_ttl_seconds() == 90 * 24 * 3600
  end
end
