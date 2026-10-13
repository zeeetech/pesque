defmodule Pesque.Record do
  @moduledoc """
  What a record has to satisfy before it is committed.

  Two things, both of which a client controls: the record's `$type` has to be
  the collection it is being written to, and, when this server ships a lexicon
  for that collection, its fields have to match it. Both answers come back as
  `{:error, _}`, so the process doing the writing never sees a record that
  passed one check and failed the other.

  Only a lexicon this server ships (`priv/lexicons`) is enforced. A collection
  no shipped lexicon names is stored as it came: the reference PDS validates
  the lexicons it bundles and stores every other collection with
  `validationStatus: "unknown"`, because the writer and the lexicon author are
  independent parties and a PDS that happens to hold someone else's schema must
  not refuse the records that schema describes.

  `validate: false` skips the field check, and any write that was not checked
  comes back as `validationStatus: "unknown"` rather than "valid". That is the
  honest answer to "store this anyway": nobody checked it, so nobody is claiming
  it is good. It is how a migration or a replay gets deliberately malformed
  records in, which is why it is a parameter and not a setting on the server.

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

  @doc """
  Whether a write to `collection` is checked against a lexicon.

  True when this server holds a record schema for the collection, which is the
  same as saying it is one of the lexicons this server ships. A collection with
  no schema is stored unvalidated. A write's `validationStatus` is "valid"
  exactly when this is true and the record passed.
  """
  @spec enforced?(String.t()) :: boolean()
  def enforced?(collection) when is_binary(collection), do: is_map(Registry.record(collection))
  def enforced?(_collection), do: false

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

  # A record is checked against the lexicon only when this server ships one. The
  # reference PDS validates the lexicons it bundles and stores every other
  # collection as it came, marked validationStatus "unknown": a collection no
  # shipped lexicon names gets the same answer, which is what makes this server
  # behave like the one a migrating account came from.
  defp check_fields(collection, record) do
    if enforced?(collection) do
      # The record is checked as it was submitted, $type and all: the validator
      # ignores a field the lexicon does not declare, which is what the spec
      # says to do with one, so there is no reason to hide the type from it.
      case Validate.validate(Registry.record(collection), record) do
        :ok -> {:ok, Map.put(record, "$type", collection)}
        {:error, errors} -> {:error, {:invalid_record, errors}}
      end
    else
      {:ok, Map.put(record, "$type", collection)}
    end
  end
end
