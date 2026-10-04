defmodule Pesque.BlobTest do
  @moduledoc """
  Blob storage: what may reach a path, what round trips, and which of the two
  orderings that look equivalent are not.
  """

  use ExUnit.Case, async: false

  alias Pesque.{Blob, CID, Storage}

  @did "did:web:example.com:user:alice"

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "put and read round trip, and the bytes land under the did's digest" do
    cid = CID.from_data("hello", CID.raw())

    assert Blob.put(@did, cid, "hello") == :ok
    assert Blob.read(@did, cid) == {:ok, "hello"}

    assert Blob.path(@did, cid) ==
             Path.join([Storage.blobs_dir(), Storage.digest_name(@did), CID.to_string(cid)])

    assert File.exists?(Blob.path(@did, cid))
    refute File.exists?(Blob.path(@did, cid) <> ".tmp")
  end

  test "read answers :enoent for a cid that was never written" do
    cid = CID.from_data("never written", CID.raw())

    assert Blob.read(@did, cid) == {:error, :enoent}
  end

  # The CID is built by parsing and then re-rendered, so a path can only ever
  # contain base32 output. Every one of these is refused by the match on the
  # decoded struct, not by a filter on the string.
  test "parse_cid turns away anything that is not a raw sha2-256 cid" do
    for attempt <- [
          "../../etc/passwd",
          "..%2f..%2fetc%2fpasswd",
          "%2e%2e%2f%2e%2e%2fetc%2fpasswd",
          "bafkrei../../../etc/passwd",
          CID.to_string(CID.from_data("x", CID.raw())) <> "/../../etc/passwd",
          "",
          "not a cid",
          "bafkrei"
        ] do
      assert Blob.parse_cid(attempt) == :error, attempt
    end

    assert Blob.parse_cid(nil) == :error
    assert Blob.parse_cid(%{}) == :error
  end

  test "parse_cid turns away a dag-cbor cid and a short digest" do
    assert Blob.parse_cid(CID.to_string(CID.from_data("x"))) == :error

    assert Blob.parse_cid(%CID{
             version: 1,
             codec: 0x55,
             hash_algo: 0x12,
             digest: :crypto.strong_rand_bytes(16)
           }) == :error

    assert Blob.parse_cid(%CID{
             version: 1,
             codec: 0x55,
             hash_algo: 0x13,
             digest: :crypto.strong_rand_bytes(32)
           }) == :error

    assert Blob.parse_cid(%CID{version: 2, codec: 0x55, hash_algo: 0x12, digest: <<0::256>>}) ==
             :error
  end

  test "parse_cid accepts a real blob cid, and the accepted path stays inside the blob dir" do
    bytes = "hello"
    {:ok, uploaded} = Blob.upload(@did, bytes, "image/jpeg")
    {:ok, cid} = Blob.parse_cid(uploaded.cid)

    assert cid == CID.from_data(bytes, CID.raw())

    assert Blob.path(@did, cid) |> String.starts_with?(Storage.blobs_dir() <> "/")
    assert Blob.path(@did, cid) == String.replace(Blob.path(@did, cid), "..", "")
  end

  test "upload rejects an empty body and one over the limit" do
    assert Blob.upload(@did, "", "image/jpeg") == {:error, :empty}

    assert Blob.upload(@did, String.duplicate("a", 5 * 1024 * 1024 + 1), "image/jpeg") ==
             {:error, :too_large}

    max = 5 * 1024 * 1024

    assert {:ok, %{size: ^max}} = Blob.upload(@did, String.duplicate("a", max), "image/jpeg")
  end

  test "the cid is over the raw bytes and nothing else" do
    {:ok, %{cid: cid}} = Blob.upload(@did, "hello", "image/jpeg")

    assert cid == CID.to_string(CID.from_data("hello", CID.raw()))
    refute String.starts_with?(cid, "bafyrei")
  end

  test "upload answers what it stored" do
    assert {:ok, %{cid: cid, size: 5, mime_type: "image/jpeg"}} =
             Blob.upload(@did, "hello", "image/jpeg")

    assert Blob.fetch(@did, CID.parse(cid)) == {:ok, "hello", "image/jpeg"}
  end

  # Same bytes, same CID, so the second upload is not a new fact. A reader who
  # already fetched the blob must keep getting the MIME type they got.
  test "uploading the same bytes again keeps the first mime type" do
    assert {:ok, %{cid: cid}} = Blob.upload(@did, "hello", "image/jpeg")
    assert {:ok, %{cid: ^cid}} = Blob.upload(@did, "hello", "text/html")

    assert Blob.fetch(@did, CID.parse(cid)) == {:ok, "hello", "image/jpeg"}
  end

  test "fetch answers not_found for a cid the repo never had" do
    cid = CID.from_data("never uploaded", CID.raw())

    assert Blob.fetch(@did, cid) == {:error, :not_found}
  end

  # A restore from a partial backup leaves rows whose files never made it. The
  # row is the authority, so this is a clean miss and not a crash.
  test "fetch answers not_found for a row whose file is gone" do
    {:ok, %{cid: cid}} = Blob.upload(@did, "hello", "image/jpeg")

    File.rm!(Blob.path(@did, CID.parse(cid)))

    assert Blob.fetch(@did, CID.parse(cid)) == {:error, :not_found}
  end

  # An upload that wrote the file and died before the insert leaves bytes no
  # row points at. fetch gates on the row, so they are unreachable.
  test "fetch does not serve a file with no row" do
    cid = CID.from_data("orphan", CID.raw())
    assert Blob.put(@did, cid, "orphan") == :ok

    assert Blob.fetch(@did, cid) == {:error, :not_found}
  end

  test "one account's blobs are not reachable through another's did" do
    {:ok, %{cid: cid}} = Blob.upload(@did, "hello", "image/jpeg")

    assert Blob.fetch("did:web:example.com:user:bob", CID.parse(cid)) == {:error, :not_found}
  end
end
