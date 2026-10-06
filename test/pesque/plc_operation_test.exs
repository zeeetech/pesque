defmodule Pesque.Plc.OperationTest do
  @moduledoc """
  The pure half of did:plc: did:key encoding, operation encoding, and the DID
  an operation mints. No network and no database.

  The genesis vector is a real operation from the did-method-plc interop suite
  (interop_tests/audit_log/valid/log_tombstone.json), with the DID and CID that
  suite publishes for it. It is the check that this encoder is byte-compatible
  with the reference, not merely self-consistent.
  """

  use ExUnit.Case, async: true

  alias Pesque.Did
  alias Pesque.Plc.Operation
  alias Pesque.Secp256k1

  # The secp256k1 generator (private key 1). Derived independently with openssl
  # and a base58btc encoder, not from this code.
  @generator_priv <<1::big-256>>
  @generator_did_key "did:key:zQ3shVc2UkAfJCdc1TR8E66J85h48P43r93q8jGPkPpjF9Ef9"

  @genesis %{
    "sig" =>
      "ZznbxHinpBI3NgEYWzXUXLA65s2U1ezJooreZlscHYQRfd4EMlijqhpikGMabs-81Tsy4Mt9Iscpmk7Uz13aAg",
    "prev" => nil,
    "type" => "plc_operation",
    "services" => %{},
    "alsoKnownAs" => ["at://op0"],
    "rotationKeys" => [
      "did:key:zQ3shmWf4f6ZwzNyjUDYw4oFQjgHWZoYZDjJYtz75YfYYrphB",
      "did:key:zQ3shr2PwdoF6kbuYYymyZq6YbGWShiTXAkdMioCPdSdPL9NV"
    ],
    "verificationMethods" => %{}
  }
  @genesis_did "did:plc:6adr3q2labdllanslzhqkqd3"
  @genesis_cid "bafyreihqa4o4gsyai22ydms6j4cua6yr6tuc7trq2temvnycadk2daniru"

  test "did:key encodes a secp256k1 public key with the multicodec prefix" do
    pub = Secp256k1.public_from_private(@generator_priv)

    assert Did.key_did(pub) == @generator_did_key
  end

  test "a real genesis operation mints its published DID and CID" do
    assert Operation.did_for(@genesis) == @genesis_did
    assert Operation.cid(@genesis) == @genesis_cid
  end

  test "an update op points prev at the previous op's CID" do
    {rotation_pub, rotation_priv} = Secp256k1.generate_keypair()
    {repo_pub, _repo_priv} = Secp256k1.generate_keypair()

    attrs = %{
      signing_key: Did.key_did(repo_pub),
      rotation_keys: [Did.key_did(rotation_pub)],
      handle: "alice.test",
      pds: "https://pds.example.com"
    }

    {genesis, did} = Operation.genesis(attrs, rotation_priv)

    assert String.starts_with?(did, "did:plc:")
    assert String.length(did) == 32
    assert genesis["prev"] == nil
    assert genesis["alsoKnownAs"] == ["at://alice.test"]

    update = Operation.update(genesis, "bob.test", rotation_priv)

    assert update["prev"] == Operation.cid(genesis)
    assert update["alsoKnownAs"] == ["at://bob.test"]
    assert update["rotationKeys"] == [Did.key_did(rotation_pub)]
    assert update["verificationMethods"] == %{"atproto" => Did.key_did(repo_pub)}

    assert update["services"] == %{
             "atproto_pds" => %{
               "type" => "AtprotoPersonalDataServer",
               "endpoint" => "https://pds.example.com"
             }
           }
  end

  test "the plc document is keyed by the stored DID, not a derived one" do
    document =
      Did.plc_document(%{
        did: @genesis_did,
        handle: "alice.test",
        pub_multibase: "zQ3shVc2UkAfJCdc1TR8E66J85h48P43r93q8jGPkPpjF9Ef9",
        endpoint: "https://pds.example.com"
      })

    assert document["id"] == @genesis_did
    assert document["alsoKnownAs"] == ["at://alice.test"]
    assert [%{"id" => @genesis_did <> "#atproto"}] = document["verificationMethod"]
    assert [%{"serviceEndpoint" => "https://pds.example.com"}] = document["service"]
  end
end
