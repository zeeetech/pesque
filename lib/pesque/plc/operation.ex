defmodule Pesque.Plc.Operation do
  @moduledoc """
  PLC operations: construction, signing, and the DID they derive.

  An operation is a map with string keys, DAG-CBOR encoded to sign and to
  hash. `prev` is the previous operation's CID as a string, or null on a
  genesis operation. The signature covers the operation without its `sig`
  field; the DID is the hash of the operation with it. Nothing here talks to
  the network, so the whole encoding is testable against a fixture.

  The field order does not matter: DAG-CBOR sorts map keys length-first then
  bytewise, which is what makes the hash canonical.
  """

  alias Pesque.Base32
  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Secp256k1

  @did_chars 24

  @type t :: map()

  @doc """
  A signed genesis operation and the DID it mints.

  `attrs` carries the `atproto` signing key and the rotation keys as did:key
  strings, the bare handle, and the PDS endpoint. `rotation_priv` signs.
  """
  @spec genesis(map(), binary()) :: {t(), String.t()}
  def genesis(attrs, rotation_priv) do
    op = attrs |> unsigned(nil) |> sign(rotation_priv)
    {op, did_for(op)}
  end

  @doc """
  A signed update operation pointing at `prev_op`.

  The fields carried forward are the previous operation's, with the handle
  replaced and `prev` set to the CID of the previous signed operation.
  """
  @spec update(t(), String.t(), binary()) :: t()
  def update(prev_op, handle, rotation_priv) do
    prev_op
    |> carry_forward(handle)
    |> Map.put("prev", cid(prev_op))
    |> sign(rotation_priv)
  end

  # The unsigned operation body for `attrs` and a previous CID or nil.
  @spec unsigned(map(), String.t() | nil) :: t()
  defp unsigned(attrs, prev) do
    %{
      "type" => "plc_operation",
      "rotationKeys" => attrs.rotation_keys,
      "verificationMethods" => %{"atproto" => attrs.signing_key},
      "alsoKnownAs" => ["at://" <> attrs.handle],
      "services" => %{
        "atproto_pds" => %{
          "type" => "AtprotoPersonalDataServer",
          "endpoint" => attrs.pds
        }
      },
      "prev" => prev
    }
  end

  # Signs an operation, adding the base64url (unpadded) `sig` field.
  @spec sign(t(), binary()) :: t()
  defp sign(op, priv) do
    sig = priv |> Secp256k1.sign(CBOR.encode(op)) |> Base.url_encode64(padding: false)
    Map.put(op, "sig", sig)
  end

  @doc "The DID a signed genesis operation mints."
  @spec did_for(t()) :: String.t()
  def did_for(op) do
    identifier =
      op
      |> CBOR.encode()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base32.encode()
      |> String.slice(0, @did_chars)

    "did:plc:" <> identifier
  end

  @doc "The CID of a signed operation, which is what a later `prev` names."
  @spec cid(t()) :: String.t()
  def cid(op) do
    op |> CBOR.encode() |> CID.from_data() |> CID.to_string()
  end

  defp carry_forward(prev_op, handle) do
    prev_op
    |> Map.take(["type", "rotationKeys", "verificationMethods", "services"])
    |> Map.put("alsoKnownAs", ["at://" <> handle])
  end
end
