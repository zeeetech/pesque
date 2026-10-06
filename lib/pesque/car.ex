defmodule Pesque.Car do
  @moduledoc """
  CAR v1: the writer for a repo's blocks, and the reader that turns one back
  into the records it carries.

  encode/2 and stream/2 frame roots and blocks; decode/1 reads them back.
  decode_repo/1 is the whole of what `com.atproto.repo.importRepo` needs from a
  CAR: the commit at its root, the record entries the MST under it reaches, and
  the bytes of every block, or an error for a CAR that is not a repo.
  """

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Varint

  @doc "roots: list of %CID{}. blocks: %{(%CID{}) => binary}. Returns iodata-ready binary."
  def encode(roots, blocks) when is_list(roots) and is_map(blocks) do
    IO.iodata_to_binary(Enum.to_list(stream(roots, sort(blocks))))
  end

  @doc """
  The same CAR encode/2 writes, as a lazy stream of chunks: the header first,
  then one chunk per block.

  Blocks are taken in the order the enumerable yields them, not sorted, so a
  caller reading from storage decides the order and no intermediate map of
  every block is needed. The laziness is the point: the blocks enumerable is
  only advanced as each chunk is written, so a caller that pulls one block at a
  time never has the rest of the repo in memory. encode/2 is this same framing
  over sort/1 collected into one binary, which is what keeps the two
  byte-identical: the header, the roots, the block order and the section
  framing are written here once.
  """
  def stream(roots, blocks) when is_list(roots) do
    header = CBOR.encode(%{"version" => 1, "roots" => roots})
    Stream.concat([[Varint.encode(byte_size(header)), header]], Stream.map(blocks, &section/1))
  end

  # Ascending CID, so the order a CAR's blocks come out in does not depend on
  # which map or table they were read from.
  defp sort(blocks) do
    Enum.sort_by(blocks, fn {%CID{} = cid, _bytes} -> CID.to_bytes(cid) end)
  end

  defp section({%CID{} = cid, bytes}) do
    cid_bytes = CID.to_bytes(cid)
    [Varint.encode(byte_size(cid_bytes) + byte_size(bytes)), cid_bytes, bytes]
  end

  @doc """
  Reads a CAR v1 back into `{roots, blocks}`, the shape encode/2 takes.

  The inverse rather than a parser: a CID is only as long as the varints in
  front of its digest say it is, and there is no other way to tell where one
  section's CID ends and its block begins. Sections are therefore required to
  split cleanly, which is what a CAR written by encode/2 does.
  """
  def decode(car) when is_binary(car) do
    {header_len, rest} = Varint.decode(car)
    <<header::binary-size(^header_len), sections::binary>> = rest
    %{"roots" => roots} = CBOR.decode!(header)
    {roots, decode_sections(sections, %{})}
  end

  defp decode_sections(<<>>, acc), do: acc

  defp decode_sections(sections, acc) do
    {len, rest} = Varint.decode(sections)
    <<payload::binary-size(^len), tail::binary>> = rest
    {cid_len, bytes} = split_section(payload)
    <<cid_bytes::binary-size(^cid_len), _::binary>> = payload
    decode_sections(tail, Map.put(acc, CID.from_bytes(cid_bytes), bytes))
  end

  defp split_section(payload) do
    {_version, rest} = Varint.decode(payload)
    {_codec, rest} = Varint.decode(rest)
    {_algo, rest} = Varint.decode(rest)
    {digest_len, rest} = Varint.decode(rest)
    cid_len = byte_size(payload) - byte_size(rest) + digest_len
    <<_cid::binary-size(^cid_len), bytes::binary>> = payload
    {cid_len, bytes}
  end

  @doc """
  Reads a CAR as an imported repo: its head commit, the records the MST under
  it reaches, and every block it carries.

  Answers `{:ok, %{commit_cid, commit, entries, records, blocks}}`: the decoded
  head commit, `entries` as `%{collection/rkey => %CID{}}` in the shape the MST
  holds it, `records` as `%{collection/rkey => {%CID{}, bytes}}` for the record
  blocks the tree points at, and `blocks` as `%{cid string => bytes}`.

  The tree is walked from the commit's own `data`, never from a block the
  header merely declares: the root has to be stored and has to decode as a
  commit before anything is read. A CAR that does not decode, names no root or
  more than one, whose root is not stored or is not a commit, whose tree names
  a block it does not carry, or whose tree holds a key that is not
  `collection/rkey` is refused whole as `{:error, :invalid_car}`. A partial
  import is not an answer this function gives: the caller either has a repo it
  can sign over or it has nothing.
  """
  def decode_repo(car) when is_binary(car) do
    {roots, blocks} = decode(car)

    with {:ok, commit_cid} <- import_root(roots),
         {:ok, commit} <- import_commit(blocks, commit_cid),
         {:ok, entries} <- import_entries(blocks, commit["data"]),
         {:ok, records} <- import_records(blocks, entries) do
      {:ok,
       %{
         commit_cid: commit_cid,
         commit: commit,
         entries: entries,
         records: records,
         blocks: Map.new(blocks, fn {cid, data} -> {CID.to_string(cid), data} end)
       }}
    end
  rescue
    _ -> {:error, :invalid_car}
  end

  # One root. A repo CAR names the head commit it was exported at, and a CAR
  # naming two states names neither, so a second root is refused rather than
  # picked between.
  defp import_root([%CID{} = cid]), do: {:ok, cid}
  defp import_root(_roots), do: {:error, :invalid_car}

  # The root has to be in the CAR and has to be a commit. The tree a repo is
  # read from is the commit's own `data`, not anything the header declares, so
  # a CAR whose root is some other block has nothing to walk.
  defp import_commit(blocks, cid) do
    case Map.fetch(blocks, cid) do
      {:ok, bytes} ->
        case CBOR.decode!(bytes) do
          %{"data" => %CID{}, "did" => did} = commit when is_binary(did) -> {:ok, commit}
          _other -> {:error, :invalid_car}
        end

      :error ->
        {:error, :invalid_car}
    end
  end

  defp import_entries(blocks, %CID{} = root) do
    with {:ok, entries} <- walk(blocks, root, []) do
      {:ok, Map.new(entries)}
    end
  end

  defp import_entries(_blocks, _root), do: {:error, :invalid_car}

  defp import_records(blocks, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, cid}, {:ok, acc} ->
      case {record_key(key), Map.fetch(blocks, cid)} do
        {{:ok, _collection, _rkey}, {:ok, data}} ->
          {:cont, {:ok, Map.put(acc, key, {cid, data})}}

        _other ->
          {:halt, {:error, :invalid_car}}
      end
    end)
  end

  # collection/rkey, both non-empty. The MST key is the record's path, so a key
  # that is not one has no record behind it to write.
  defp record_key(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [collection, rkey] when collection != "" and rkey != "" -> {:ok, collection, rkey}
      _other -> {:error, :invalid_car}
    end
  end

  defp record_key(_key), do: {:error, :invalid_car}

  # The tree as stored, walked from its root. The node shape is the one Mst
  # writes: a left subtree, then entries carrying a prefix-compressed key, the
  # subtree to the entry's right, and the record CID the entry points at.
  defp walk(blocks, %CID{} = cid, acc) do
    case Map.fetch(blocks, cid) do
      {:ok, bytes} -> walk_node(blocks, CBOR.decode!(bytes), acc)
      :error -> {:error, :invalid_car}
    end
  end

  defp walk_node(blocks, %{"l" => left, "e" => entries} = node, acc) do
    if Map.has_key?(node, "$type") do
      {:ok, acc}
    else
      with {:ok, acc} <- walk_child(blocks, left, acc) do
        walk_entries(blocks, entries, "", acc)
      end
    end
  end

  defp walk_node(_blocks, _other, acc), do: {:ok, acc}

  defp walk_entries(_blocks, [], _last, acc), do: {:ok, acc}

  defp walk_entries(blocks, [entry | rest], last, acc) do
    with %{"k" => %CBOR.Bytes{data: suffix}, "p" => shared, "t" => tree, "v" => %CID{} = value} <-
           entry,
         true <- is_integer(shared) and shared >= 0 do
      key = binary_part(last, 0, min(shared, byte_size(last))) <> suffix

      with {:ok, acc} <- walk_child(blocks, tree, [{key, value} | acc]) do
        walk_entries(blocks, rest, key, acc)
      end
    else
      _other -> {:error, :invalid_car}
    end
  end

  defp walk_child(_blocks, nil, acc), do: {:ok, acc}
  defp walk_child(blocks, %CID{} = cid, acc), do: walk(blocks, cid, acc)
  defp walk_child(_blocks, _other, _acc), do: {:error, :invalid_car}
end
