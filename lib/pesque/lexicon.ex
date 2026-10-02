defmodule Pesque.Lexicon do
  @moduledoc """
  Converts between lexicon JSON (what XRPC clients send) and the internal
  representation the CBOR encoder understands.

    {"$link": "<cid>"}   <->  %Pesque.CID{}
    {"$bytes": "<b64>"}  <->  %Pesque.CBOR.Bytes{}
  """

  alias Pesque.{CBOR, CID}

  def from_json(%{"$link" => link} = map) when map_size(map) == 1 and is_binary(link),
    do: CID.parse(link)

  def from_json(%{"$bytes" => b64} = map) when map_size(map) == 1 and is_binary(b64),
    do: %CBOR.Bytes{data: Base.decode64!(b64)}

  def from_json(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, from_json(v)} end)

  def from_json(list) when is_list(list),
    do: Enum.map(list, &from_json/1)

  def from_json(other), do: other

  def to_json(%CID{} = cid), do: %{"$link" => CID.to_string(cid)}
  def to_json(%CBOR.Bytes{data: data}), do: %{"$bytes" => Base.encode64(data)}

  def to_json(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, to_json(v)} end)

  def to_json(list) when is_list(list),
    do: Enum.map(list, &to_json/1)

  def to_json(other), do: other
end
