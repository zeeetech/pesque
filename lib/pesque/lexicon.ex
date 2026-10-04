defmodule Pesque.Lexicon do
  @moduledoc """
  Converts between lexicon JSON (what XRPC clients send) and the internal
  representation the CBOR encoder understands.

    {"$link": "<cid>"}   <->  %Pesque.CID{}
    {"$bytes": "<b64>"}  <->  %Pesque.CBOR.Bytes{}

  from_json/1 answers {:ok, term} or {:error, reason}: both "$link" and
  "$bytes" carry values a client controls, and one bad link deep inside a
  record has to abort the whole conversion rather than take down whatever
  process was holding it.
  """

  alias Pesque.CBOR
  alias Pesque.CID

  def from_json(%{"$link" => link} = map) when map_size(map) == 1 and is_binary(link) do
    case CID.safe_parse(link) do
      {:ok, cid} -> {:ok, cid}
      :error -> {:error, :invalid_link}
    end
  end

  def from_json(%{"$bytes" => b64} = map) when map_size(map) == 1 and is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, data} -> {:ok, %CBOR.Bytes{data: data}}
      :error -> {:error, :invalid_bytes}
    end
  end

  def from_json(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case from_json(value) do
        {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def from_json(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case from_json(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  # DAG-CBOR holds uint64 and text strings have to be valid UTF-8. JSON admits
  # neither limit, so a client can carry both, and the encoder raises on them
  # in the middle of a commit. Turning them away here is what keeps this
  # function's promise that a bad value aborts the conversion instead of the
  # process holding it. Nothing else JSON produces can raise: object keys are
  # always strings, and nil, true, false and floats all encode.
  def from_json(int) when is_integer(int) do
    if int >= -0x1_0000_0000_0000_0000 and int <= 0xFFFF_FFFF_FFFF_FFFF,
      do: {:ok, int},
      else: {:error, :unencodable}
  end

  def from_json(bin) when is_binary(bin) do
    if String.valid?(bin), do: {:ok, bin}, else: {:error, :unencodable}
  end

  def from_json(other), do: {:ok, other}

  def to_json(%CID{} = cid), do: %{"$link" => CID.to_string(cid)}
  def to_json(%CBOR.Bytes{data: data}), do: %{"$bytes" => Base.encode64(data)}

  def to_json(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, to_json(v)} end)

  def to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)

  def to_json(other), do: other
end
