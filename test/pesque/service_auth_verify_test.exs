defmodule Pesque.ServiceAuthVerifyTest do
  use ExUnit.Case, async: false

  alias Pesque.Base58
  alias Pesque.Secp256k1
  alias Pesque.ServiceAuth

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @audience "did:web:pds.example.com"
  @lxm "com.atproto.server.createAccount"

  # The injected directory answers the account's document, and tells the test
  # process when it is asked, so a token refused before resolution is
  # observable as an absent message.
  defmodule Directory do
    def resolve(did) do
      case :persistent_term.get(:service_auth_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, {:resolved, did})
      end

      :persistent_term.get(:service_auth_test_result, {:error, :not_found})
    end
  end

  setup do
    {pub, priv} = Secp256k1.generate_keypair()

    :persistent_term.put(:service_auth_test_pid, self())
    :persistent_term.put(:service_auth_test_result, {:ok, document(pub)})
    Application.put_env(:pesque, :did_resolver_directory, Directory)

    on_exit(fn ->
      :persistent_term.erase(:service_auth_test_pid)
      :persistent_term.erase(:service_auth_test_result)
      Application.delete_env(:pesque, :did_resolver_directory)
    end)

    %{priv: priv, pub: pub}
  end

  test "a correctly signed token verifies and answers the issuer", %{priv: priv} do
    assert ServiceAuth.verify(token(priv, claims()), @audience, @lxm) == {:ok, @did}
    assert_received {:resolved, @did}
  end

  test "a token signed by the wrong key fails", %{priv: _priv} do
    {_other_pub, other_priv} = Secp256k1.generate_keypair()

    assert ServiceAuth.verify(token(other_priv, claims()), @audience, @lxm) ==
             {:error, :invalid_signature}
  end

  test "a token for another audience fails", %{priv: priv} do
    other = claims(%{"aud" => "did:web:other.example.com"})

    assert ServiceAuth.verify(token(priv, other), @audience, @lxm) == {:error, :aud_mismatch}
  end

  test "a token for another method fails", %{priv: priv} do
    other = claims(%{"lxm" => "com.atproto.sync.getRepo"})

    assert ServiceAuth.verify(token(priv, other), @audience, @lxm) == {:error, :lxm_mismatch}
  end

  test "a token without lxm fails", %{priv: priv} do
    without = Map.delete(claims(), "lxm")

    assert ServiceAuth.verify(token(priv, without), @audience, @lxm) == {:error, :lxm_mismatch}
  end

  test "an expired token fails", %{priv: priv} do
    expired = claims(%{"exp" => System.system_time(:second) - 1})

    assert ServiceAuth.verify(token(priv, expired), @audience, @lxm) == {:error, :expired}
  end

  test "a token with alg none fails before any resolution", %{priv: priv} do
    header = %{"typ" => "JWT", "alg" => "none"}

    assert ServiceAuth.verify(token(priv, claims(), header), @audience, @lxm) ==
             {:error, :unsupported_alg}

    refute_received {:resolved, _}
  end

  test "an ES256 token is refused", %{priv: priv} do
    header = %{"typ" => "JWT", "alg" => "ES256"}

    assert ServiceAuth.verify(token(priv, claims(), header), @audience, @lxm) ==
             {:error, :unsupported_alg}
  end

  test "a token whose typ is not JWT is refused", %{priv: priv} do
    header = %{"typ" => "at+jwt", "alg" => "ES256K"}

    assert ServiceAuth.verify(token(priv, claims(), header), @audience, @lxm) ==
             {:error, :invalid_typ}
  end

  test "a malformed token fails before any resolution" do
    assert ServiceAuth.verify("not-a-jwt", @audience, @lxm) == {:error, :malformed_jwt}
    assert ServiceAuth.verify("a.b.c.d", @audience, @lxm) == {:error, :malformed_jwt}
    refute_received {:resolved, _}
  end

  test "a token whose issuer does not resolve is an error, not a raise", %{priv: priv} do
    :persistent_term.put(:service_auth_test_result, {:error, :not_found})

    assert ServiceAuth.verify(token(priv, claims()), @audience, @lxm) == {:error, :not_found}
  end

  test "a legacy uncompressed verification method verifies", %{priv: priv} do
    {uncompressed, ^priv} = :crypto.generate_key(:ecdh, :secp256k1, priv)
    :persistent_term.put(:service_auth_test_result, {:ok, legacy_document(uncompressed)})

    assert ServiceAuth.verify(token(priv, claims()), @audience, @lxm) == {:ok, @did}
  end

  test "a did:key verification method verifies", %{priv: priv, pub: pub} do
    :persistent_term.put(:service_auth_test_result, {:ok, did_key_document(pub)})

    assert ServiceAuth.verify(token(priv, claims()), @audience, @lxm) == {:ok, @did}
  end

  defp token(priv, claims, header \\ %{"typ" => "JWT", "alg" => "ES256K"}) do
    input = encode(JSON.encode!(header)) <> "." <> encode(JSON.encode!(claims))
    input <> "." <> encode(Secp256k1.sign(priv, input))
  end

  defp encode(bin), do: Base.url_encode64(bin, padding: false)

  defp claims(overrides \\ %{}) do
    Enum.into(overrides, %{
      "iss" => @did,
      "aud" => @audience,
      "lxm" => @lxm,
      "iat" => System.system_time(:second),
      "exp" => System.system_time(:second) + 60
    })
  end

  defp document(pub) do
    %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => @did <> "#atproto",
          "type" => "Multikey",
          "controller" => @did,
          "publicKeyMultibase" => Secp256k1.public_key_multibase(pub)
        }
      ]
    }
  end

  defp legacy_document(uncompressed_pub) do
    %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => @did <> "#atproto",
          "type" => "EcdsaSecp256k1VerificationKey2019",
          "controller" => @did,
          "publicKeyMultibase" => "z" <> Base58.encode(uncompressed_pub)
        }
      ]
    }
  end

  defp did_key_document(pub) do
    %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => @did <> "#atproto",
          "type" => "Multikey",
          "controller" => @did,
          "publicKeyMultibase" => "did:key:" <> Secp256k1.public_key_multibase(pub)
        }
      ]
    }
  end
end
