defmodule Pesque.Commit do
  @moduledoc """
  The pure commit protocol: everything between a validated write and the
  bytes that get stored and streamed. MST rebuild, DAG-CBOR encoding,
  secp256k1 signing, CAR encoding, and the result map a write answers
  with. No database, no processes: the RepoServer owns the state, the
  transaction, and the registry fan-out.

  The seq number and the block set a frame carries can only be known
  inside that transaction, so the protocol runs in two steps: commit/2
  turns the current entries/rev/tid plus writes into the new
  entries/rev/tid, the commit's CIDs and blocks, and the result map, and
  frame/4 turns that plus the claimed seq and the blocks the transaction
  will actually insert into the frame binary.
  """

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Car
  alias Pesque.Lexicon
  alias Pesque.Mst
  alias Pesque.Secp256k1
  alias Pesque.Tid

  @doc """
  Encodes one checked record into the change a commit consumes.

  from_json/1 is what turns a client's $link and $bytes into the
  structures CBOR understands, and it is the last point at which a bad
  value can be turned away: past it the encoder raises rather than
  answering a tuple.
  """
  def encode_write(entries, action, key, record) do
    case Lexicon.from_json(record) do
      {:ok, internal} ->
        data = CBOR.encode(internal)
        cid = CID.from_data(data)

        {:ok,
         %{
           action: write_action(action, entries, key),
           key: key,
           cid: cid,
           data: data
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs the protocol over `changes` and returns the new entries/rev/tid
  plus everything the transaction and the frame need: root and commit
  CIDs, every block the commit creates, and the result map.
  """
  def commit(
        %{
          did: did,
          clock_id: clock_id,
          priv: priv,
          entries: entries,
          rev: prev_rev,
          tid_int: tid_int
        },
        changes
      ) do
    entries2 =
      Enum.reduce(changes, entries, fn
        %{action: "delete", key: key}, acc -> Map.delete(acc, key)
        %{key: key, cid: cid}, acc -> Map.put(acc, key, cid)
      end)

    {root_cid, node_blocks} = Mst.build(entries2)
    {rev, tid_int} = Tid.next(tid_int, clock_id)

    unsigned = %{
      "did" => did,
      "version" => 3,
      "data" => root_cid,
      "rev" => rev,
      "prev" => nil
    }

    sig = Secp256k1.sign(priv, CBOR.encode(unsigned))
    commit_obj = Map.put(unsigned, "sig", %CBOR.Bytes{data: sig})
    commit_bytes = CBOR.encode(commit_obj)
    commit_cid = CID.from_data(commit_bytes)

    all_blocks =
      node_blocks
      |> Map.merge(Map.new(for %{cid: cid, data: data} <- changes, data != nil, do: {cid, data}))
      |> Map.put(commit_cid, commit_bytes)

    result = %{
      "commit" => %{"cid" => CID.to_string(commit_cid), "rev" => rev},
      "changes" =>
        Enum.map(changes, fn c ->
          %{
            "uri" => "at://" <> did <> "/" <> c.key,
            "cid" => if(c.cid, do: CID.to_string(c.cid)),
            "action" => c.action
          }
        end)
    }

    {:ok,
     %{
       did: did,
       prev_rev: prev_rev,
       entries: entries2,
       rev: rev,
       tid_int: tid_int,
       root_cid: root_cid,
       commit_cid: commit_cid,
       all_blocks: all_blocks,
       result: result
     }}
  end

  @doc """
  The firehose frame: the CAR of the blocks the transaction actually
  inserted, in a #commit envelope. `new_blocks` carries the CID strings
  the transaction deduplicated against, parsed back into CIDs here.
  """
  def frame(
        %{did: did, prev_rev: prev_rev, rev: rev, commit_cid: commit_cid},
        seq,
        new_blocks,
        changes
      ) do
    car =
      Car.encode(
        [commit_cid],
        Map.new(new_blocks, fn {cid_string, bytes} -> {CID.parse(cid_string), bytes} end)
      )

    ops =
      Enum.map(changes, fn c ->
        %{"action" => c.action, "path" => c.key, "cid" => c.cid}
      end)

    header = CBOR.encode(%{"op" => 1, "t" => "#commit"})

    body =
      CBOR.encode(%{
        "seq" => seq,
        "rebase" => false,
        "tooBig" => false,
        "repo" => did,
        "commit" => commit_cid,
        "rev" => rev,
        "since" => prev_rev,
        "blocks" => %CBOR.Bytes{data: car},
        "ops" => ops,
        "blobs" => [],
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    header <> body
  end

  defp write_action(:create, _entries, _key), do: "create"

  defp write_action(:put, entries, key),
    do: if(Map.has_key?(entries, key), do: "update", else: "create")
end
