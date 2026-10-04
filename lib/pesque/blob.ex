defmodule Pesque.Blob do
  @moduledoc """
  Blob bytes on disk, and the row that makes them reachable.

  Bytes live at data/blobs/<digest of did>/<cid>. The blobs row records which
  MIME type a CID was uploaded with, and it is the authority: fetch/2 reads
  the row first and only then the file, so an orphaned file from a crashed
  upload is never served and a row whose file is gone is a clean miss rather
  than a crash.
  """

  alias Pesque.CID
  alias Pesque.RepoStore
  alias Pesque.Storage

  @max_blob_bytes 5 * 1024 * 1024
  @raw_codec 0x55
  @sha2_256 0x12

  @doc "Largest upload accepted, in bytes."
  def max_bytes, do: @max_blob_bytes

  @doc "Path of the blob file for a DID and CID."
  def path(did, %CID{} = cid) do
    Path.join([Storage.blobs_dir(), Storage.digest_name(did), CID.to_string(cid)])
  end

  @doc """
  Writes the bytes, then renames them onto the final path.

  The rename is the point, not decoration. A crash partway through the write
  would otherwise leave a partial file at the final path, the next upload of
  those same bytes would see it present and skip the write, and the truncated
  file would then be served forever. Rename is atomic on POSIX.

  A filesystem failure is :unwritable rather than the posix reason: the causes
  differ per platform, and a caller enumerating them will miss one and crash.
  """
  def put(did, %CID{} = cid, bytes) do
    final = path(did, cid)
    tmp = final <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(final)),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, _reason} -> {:error, :unwritable}
    end
  end

  @doc "Reads the bytes stored at a CID, or {:error, :enoent}."
  def read(did, %CID{} = cid), do: File.read(path(did, cid))

  @doc """
  Parses a CID and accepts it only if it can name a blob.

  Parsing is not validating: "bafkqaaa" parses without complaint and comes
  back as a struct no blob should have. So the test is a match on the decoded
  struct, not a filter on the input string, and nothing a request supplies
  reaches a path except by passing through it. Base32 output is [a-z2-7], so
  no separator, no dot and no ".." can survive the round trip; a dag-cbor
  CID, a 16-byte digest, a truncated CID and a string that is not base32 are
  all turned away by the same match.
  """
  def parse_cid(%CID{} = cid) do
    case cid do
      %CID{
        version: 1,
        codec: @raw_codec,
        hash_algo: @sha2_256,
        digest: <<_::binary-size(32)>>
      } ->
        {:ok, cid}

      _ ->
        :error
    end
  end

  def parse_cid(cid) do
    case CID.safe_parse(cid) do
      {:ok, parsed} -> parse_cid(parsed)
      :error -> :error
    end
  end

  @doc """
  Stores bytes under the CID of the bytes themselves and records the row.

  The order is load-bearing. Oversize and empty are rejected before anything
  is written, the file goes down before the row does, so a failed insert
  leaves an orphan file that fetch/2 cannot reach. The other order leaves a
  served row pointing at a file that does not exist, which is a 500 on every
  read of that CID.
  """
  def upload(did, bytes, content_type) do
    size = byte_size(bytes)

    cond do
      size == 0 -> {:error, :empty}
      size > @max_blob_bytes -> {:error, :too_large}
      true -> store(did, bytes, content_type, size)
    end
  end

  defp store(did, bytes, content_type, size) do
    cid = CID.from_data(bytes, CID.raw())
    cid_string = CID.to_string(cid)

    with :ok <- put(did, cid, bytes) do
      RepoStore.put_blob!(did, cid_string, content_type, size)
      {:ok, %{cid: cid_string, size: size, mime_type: content_type}}
    end
  end

  @doc """
  Reads a stored blob, gated on the row.

  The row decides and the file is only the payload. A file with no row is an
  orphan from an upload that did not finish and is never served; a row with
  no file answers not_found, so an operator restoring a partial backup gets
  a clean miss instead of a crash.
  """
  def fetch(did, %CID{} = cid) do
    case RepoStore.get_blob(did, CID.to_string(cid)) do
      nil ->
        {:error, :not_found}

      row ->
        case read(did, cid) do
          {:ok, bytes} -> {:ok, bytes, row.mime_type}
          {:error, _reason} -> {:error, :not_found}
        end
    end
  end
end
