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
  the type is the collection and the collection is the type. A client that sent
  `"$type": null` is refused instead: the spec says a record object always
  carries its type, and a null one gives a consumer off the firehose nothing to
  dispatch on and can never be validated by anything.
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
      {:ok, Map.put(record, "$type", collection)}
    end
  end

  def check(_collection, _record, _opts), do: {:error, :missing_params}

  # Absent and null are different answers, so they are looked up separately.
  # Absent means the client left the type to the collection it is writing to;
  # null means the client sent a type that is not one.
  defp verify(collection, record) do
    case Map.fetch(record, "$type") do
      {:ok, nil} ->
        {:error, {:invalid_record, [{["$type"], :missing_type}]}}

      {:ok, type} when type != collection ->
        {:error, {:type_mismatch, type, collection}}

      _ ->
        check_fields(collection, record)
    end
  end

  defp check_fields(collection, record) do
    if is_map(schema = Registry.record(collection)) do
      # The record is checked as it was submitted, $type and all: the validator
      # ignores a field the lexicon does not declare, which is what the spec
      # says to do with one, so there is no reason to hide the type from it.
      case Validate.validate(schema, record) do
        :ok -> {:ok, Map.put(record, "$type", collection)}
        {:error, errors} -> {:error, {:invalid_record, errors}}
      end
    else
      {:error, :unknown_collection}
    end
  end
end
