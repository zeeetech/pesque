defmodule Pesque.Car do
  @moduledoc "CAR v1 writer: a dag-cbor header followed by varint-framed blocks."

  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Varint

  @doc "roots: list of %CID{}. blocks: %{(%CID{}) => binary}. Returns iodata-ready binary."
  def encode(roots, blocks) when is_list(roots) and is_map(blocks) do
    header = CBOR.encode(%{"version" => 1, "roots" => roots})

    sections =
      blocks
      |> Enum.sort_by(fn {%CID{} = cid, _bytes} -> CID.to_bytes(cid) end)
      |> Enum.map(fn {%CID{} = cid, bytes} ->
        cid_bytes = CID.to_bytes(cid)
        [Varint.encode(byte_size(cid_bytes) + byte_size(bytes)), cid_bytes, bytes]
      end)

    IO.iodata_to_binary([Varint.encode(byte_size(header)), header | sections])
  end
end
