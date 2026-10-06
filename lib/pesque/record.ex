defmodule Pesque.Record do
  @moduledoc """
  What a record has to satisfy before it is committed.

  Two things, both of which a client controls: the record's `$type` has to be
  the collection it is being written to, and its fields have to match the
  lexicon this server holds for that collection. Both answers come back as
  `{:error, _}`, so the process doing the writing never sees a record that
  passed one check and failed the other.

  `validate: false` skips both, and the write comes back as
  `validationStatus: "unknown"` rather than "valid". That is the honest answer
  to "store this anyway": nobody checked it, so nobody is claiming it is good.
  It is how a migration or a replay gets deliberately malformed records in,
  which is why it is a parameter and not a setting on the server.

  The record goes out with `$type` filled in when the client left it out, since
  the type is the collection and the collection is the type. Filling it in
  after validation rather than before is deliberate: no vendored record lexicon
  declares `$type` as a property, and `app.bsky.actor.profile` is the one
  record with no `required`, which is the closed case, so a `$type` sitting in
  the value is an undeclared field on exactly the record type every client is
  required to send one.
  """

  alias Pesque.Lexicon.Registry
  alias Pesque.Lexicon.Validate

  @doc """
  Checks a record against `collection` and answers the one to commit.

  Options: `:validate`, defaulting to true.
  """
  @spec check(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(collection, record, opts \\ [])

  def check(collection, record, opts) when is_map(record) do
    if Keyword.get(opts, :validate, true) do
      verify(collection, record)
    else
      {:ok, Map.put_new(record, "$type", collection)}
    end
  end

  defp verify(collection, record) do
    cond do
      record["$type"] not in [nil, collection] ->
        {:error, {:type_mismatch, record["$type"], collection}}

      is_map(schema = Registry.record(collection)) ->
        case Validate.validate(schema, Map.delete(record, "$type")) do
          :ok -> {:ok, Map.put_new(record, "$type", collection)}
          {:error, errors} -> {:error, {:invalid_record, errors}}
        end

      true ->
        {:error, :unknown_collection}
    end
  end
end
