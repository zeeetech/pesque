defmodule Pesque.Plc.Directory do
  @moduledoc """
  The PLC directory over HTTPS: submit an operation, resolve a DID.

  The base URL is configuration, so it is not a caller's choice, but the
  requests go through `Pesque.OAuth.Fetch`, which keeps the same scheme and
  address checks as the OAuth metadata path. A test never reaches the live
  directory: it swaps the client with `:plc_client`.
  """

  alias Pesque.OAuth.Fetch

  # An operation is capped at 7500 bytes by the method; a DID document is
  # smaller still. This is the response cap, generous for both.
  @max_bytes 1_048_576

  @doc "Submits a signed operation for `did`. Answers :ok or {:error, reason}."
  def submit(did, op) do
    Fetch.post_json(url(did), op, @max_bytes)
  end

  @doc "Resolves a DID document. Answers {:ok, document} or {:error, reason}."
  def resolve(did) do
    Fetch.json(url(did), @max_bytes)
  end

  defp url(did) do
    base = Pesque.plc_directory()
    URI.merge(URI.parse(base), "/" <> URI.encode_www_form(did))
  end
end
