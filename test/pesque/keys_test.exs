defmodule Pesque.KeysTest do
  use ExUnit.Case, async: true

  alias Pesque.Keys

  setup do
    did = "did:web:example.com:user:" <> uniq()
    on_exit(fn -> Keys.delete(did) end)
    %{did: did}
  end

  test "the filename is filesystem safe" do
    path = Keys.path("did:web:example.com:user:alice")

    assert Path.basename(path) =~ ~r/\A[A-Za-z0-9_-]+\.key\z/
    assert Path.dirname(path) == Pesque.Storage.keys_dir()
  end

  # did:web percent-encodes the port into the path segment, so a name built by
  # stripping disallowed characters merges these two DIDs onto one file and
  # two accounts end up signing with one key.
  test "a did differing only in an encoded character gets its own file" do
    plain = "did:web:example.com:user:alice"
    encoded = "did:web:example.com:user:alice%3Afoo"

    refute Keys.path(plain) == Keys.path(encoded)
  end

  test "create_exclusive claims the file once", %{did: did} do
    assert {:ok, first} = Keys.create_exclusive(did)
    assert {:error, :eexist} = Keys.create_exclusive(did)

    assert {:ok, priv} = Keys.load(did)
    assert priv == first.priv
    assert first.pub == Pesque.Secp256k1.public_from_private(priv)
  end

  test "the key file is private", %{did: did} do
    {:ok, _key} = Keys.create_exclusive(did)

    assert %File.Stat{mode: mode} = File.stat!(Keys.path(did))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "ensure returns the existing key rather than minting a second one", %{did: did} do
    {:ok, first} = Keys.create_exclusive(did)
    {:ok, second} = Keys.ensure(did)

    assert second.priv == first.priv
    assert second.pub_multibase == first.pub_multibase
  end

  test "ensure mints a key when the file is absent", %{did: did} do
    assert {:error, :enoent} = Keys.load(did)
    assert {:ok, key} = Keys.ensure(did)

    assert {:ok, again} = Keys.ensure(did)
    assert again.priv == key.priv
  end

  test "the multibase a key derives round trips back to the public key", %{did: did} do
    {:ok, key} = Keys.create_exclusive(did)

    assert Keys.public_key_multibase(key.priv) == key.pub_multibase
  end

  defp uniq, do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
