defmodule Pesque.BlobUploadOrderTest do
  @moduledoc """
  The invariant live backup stands on: `Blob.upload/3` writes the file
  before the row that serves it, so a row insert that fails after the bytes
  landed leaves an orphan file no reader can reach, never a row whose bytes
  are missing.
  """

  use ExUnit.Case, async: false

  alias Pesque.Blob
  alias Pesque.CID
  alias Pesque.RepoStore

  @did "did:web:example.com:user:alice"

  setup do
    Pesque.DataCase.setup()
    :ok
  end

  test "a failed row insert leaves the file, and no row points at it" do
    bytes = "backup depends on this order"
    cid = CID.from_data(bytes, CID.raw())

    # mime_type is NOT NULL on the blobs table: the one way to make the row
    # insert fail after the bytes are on disk, without mocking anything. The
    # violation surfaces raw (Exqlite.Error); this test is about what is on
    # disk afterwards, not about error shaping.
    assert_raise Exqlite.Error, ~r/NOT NULL constraint failed: blobs.mime_type/, fn ->
      Blob.upload(@did, bytes, nil)
    end

    assert File.exists?(Blob.path(@did, cid))
    assert RepoStore.get_blob(@did, CID.to_string(cid)) == nil
  end
end
