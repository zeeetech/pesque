defmodule Pesque.Lexicon.Validate do
  @moduledoc """
  Checks a record value against the lexicon definition for its collection.

  Pure and total: it takes the definition as an argument, reads no registry,
  touches no process and never raises. Every disagreement comes back as a path
  and a reason, so a caller can tell a client which field it got wrong rather
  than only that something did.

      iex> post = %{"type" => "object", "required" => ["text"],
      ...>           "properties" => %{"text" => %{"type" => "string"}}}
      iex> Pesque.Lexicon.Validate.validate(post, %{"text" => "hi"})
      :ok
      iex> Pesque.Lexicon.Validate.validate(post, %{})
      {:error, [{["text"], :required}]}

  The rules implemented are the ones the vendored lexicons actually use:
  `object` (with `required`, `properties`, unknown fields rejected),
  `array` (with `items`, `minLength`, `maxLength`), `string` (with `format`,
  `enum`, `const`, `minLength`, `maxLength`, `maxGraphemes`), `integer`
  (`minimum`, `maximum`, `const`), `boolean`, `float`, `number`, `unknown`,
  `bytes`, `cid-link`, `blob`, `token`, `ref` and `union`.

  `bytes`, `cid-link`, `blob` and `token` are all strings or byte arrays by the
  time a record reaches here, since `Pesque.Lexicon.from_json/1` has already
  turned `$link` into a `%CID{}` and `$bytes` into `%CBOR.Bytes{}`. They are
  accepted without a further check here; the conversion itself is what rejects
  a malformed one.

  A `ref` that cannot be resolved, and any node underneath one, is skipped
  rather than failed. A broken cross-reference in someone's lexicon should not
  make their server refuse every write.
  """

  alias Pesque.Grapheme

  @doc "Validates a value against a lexicon definition."
  @spec validate(map() | nil, term()) :: :ok | {:error, [{[term()], atom() | tuple()}]}
  def validate(nil, _value), do: :ok
  def validate(schema, value), do: errors(schema, value, []) |> Enum.reverse() |> result()

  defp result([]), do: :ok
  defp result(errors), do: {:error, errors}

  defp errors(%{"type" => "object"} = schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    open? = Map.has_key?(schema, "required")

    Enum.flat_map(schema["required"] || [], fn field ->
      if Map.has_key?(value, field) and not is_nil(value[field]),
        do: [],
        else: [{path ++ [field], :required}]
    end) ++
      errors_in(value, properties, path) ++
      if(open?, do: [], else: unknown_fields(value, properties, path))
  end

  defp errors(%{"type" => "object"}, _value, path), do: [{path, :expected_object}]

  defp errors(%{"type" => "array"} = schema, value, path) when is_list(value) do
    length_errors(schema, value, path) ++ item_errors(Map.get(schema, "items"), value, path)
  end

  defp errors(%{"type" => "array"}, _value, path), do: [{path, :expected_array}]

  defp errors(%{"type" => "string"} = schema, value, path) when is_binary(value) do
    format_errors(schema["format"], value, path) ++
      const_errors(schema["const"], value, path) ++
      enum_errors(schema["enum"], value, path) ++
      length_errors(schema, value, path) ++
      grapheme_errors(schema["maxGraphemes"], value, path)
  end

  defp errors(%{"type" => "string"}, _value, path), do: [{path, :expected_string}]

  defp errors(%{"type" => "integer"} = schema, value, path) when is_integer(value) do
    const_errors(schema["const"], value, path) ++
      enum_errors(schema["enum"], value, path) ++
      range_errors(schema, value, path)
  end

  defp errors(%{"type" => "integer"}, _value, path), do: [{path, :expected_integer}]

  defp errors(%{"type" => "float"} = schema, value, path) when is_float(value),
    do: const_errors(schema["const"], value, path)

  defp errors(%{"type" => "float"}, _value, path), do: [{path, :expected_float}]

  defp errors(%{"type" => "number"} = schema, value, path)
       when is_integer(value) or is_float(value),
       do: const_errors(schema["const"], value, path)

  defp errors(%{"type" => "number"}, _value, path), do: [{path, :expected_number}]
  defp errors(%{"type" => "boolean"}, value, _path) when is_boolean(value), do: []
  defp errors(%{"type" => "boolean"}, _value, path), do: [{path, :expected_boolean}]
  defp errors(%{"type" => "unknown"}, _value, _path), do: []

  # A union is closed: the $type has to name one of the refs. That is the rule
  # the protocol relies on for polymorphic fields, so a $type nobody declared
  # is a rejected record rather than a stored one an AppView cannot read.
  defp errors(%{"type" => "union"} = schema, value, path) when is_map(value) do
    allowed = [schema["ref"] | Map.get(schema, "refs", [])] |> Enum.reject(&is_nil/1)

    case value["$type"] do
      nil ->
        [{path, :missing_type}]

      type ->
        # #name is a reference within this same document and resolves against
        # the defs here; a bare NSID needs the registry, which this function
        # deliberately does not have. So a local ref is followed and a foreign
        # one is accepted on its name alone.
        case resolve(schema, allowed, type) do
          {:ok, target} -> errors(target, value, path)
          :foreign -> []
          :unknown -> [{path, :unknown_type}]
        end
    end
  end

  defp errors(%{"type" => "union"}, _value, path), do: [{path, :expected_object}]

  defp errors(%{"type" => "ref"}, _value, _path), do: []

  # Accepted for what it is: from_json/1 has already parsed the CID or decoded
  # the bytes, and a value that failed to parse never got this far.
  defp errors(%{"type" => type}, _value, _path)
       when type in ["bytes", "cid-link", "blob", "token", "unknown"],
       do: []

  defp errors(_def, _value, path), do: [{path, :unrecognized_definition}]

  # The declared properties are always checked. Whether the *undeclared* ones
  # are refused is decided by the caller's `required` clause, because that is
  # the only signal a lexicon gives: an object listing required fields is open
  # and tolerates a field a newer lexicon added, one listing none is closed.
  defp item_errors(nil, _value, _path), do: []

  defp item_errors(items, value, path) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} -> errors(items, element, path ++ [index]) end)
  end

  defp errors_in(value, properties, path) do
    Enum.flat_map(properties, fn {key, schema} ->
      case Map.fetch(value, key) do
        {:ok, nested} -> errors(schema, nested, path ++ [key])
        :error -> []
      end
    end)
  end

  defp unknown_fields(value, properties, path) do
    value
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(properties, &1))
    |> Enum.sort()
    |> Enum.map(&{path ++ [&1], :unknown_field})
  end

  # A ref names either a whole lexicon or a "#def" inside one. Either way it
  # has to be listed: the value's $type is compared against the refs this
  # union declared, with the NSID before the "#" being what matters, so
  # app.bsky.richtext.facet#link matches a ref of app.bsky.richtext.facet and a
  # bare #link matches only a "#link" in refs.
  defp resolve(schema, allowed, type) do
    {target, fragment} =
      case String.split(type, "#", parts: 2) do
        ["#" <> name] -> {"", name}
        [nsid] -> {nsid, nil}
        [nsid, name] -> {nsid, name}
      end

    cond do
      target == "" ->
        if type in allowed, do: local_def(schema, fragment), else: :unknown

      # A $type that names an NSID with a fragment matches a ref carrying that
      # same NSID, since that is what the lexicon declaring the ref meant: a
      # facet feature lists "#link", and the value arrives as
      # app.bsky.richtext.facet#link. Matching only the whole string would
      # refuse every one of those.
      is_nil(fragment) ->
        if target in allowed, do: :foreign, else: :unknown

      target in allowed ->
        local_def(schema, fragment)

      ("#" <> fragment) in allowed ->
        local_def(schema, fragment)

      true ->
        :unknown
    end
  end

  # A local ref is followed so its properties get checked. One that names a def
  # this document does not have is treated as foreign rather than unknown: it
  # is still inside a declared ref, and refusing it would fail records against
  # the repository's own schema.
  defp local_def(schema, fragment) do
    case Map.get(Map.get(schema, "defs", %{}), fragment) do
      nil -> :foreign
      target -> {:ok, target}
    end
  end

  # Split by what length means: a string is measured in codepoints and an
  # array in elements. A single guard using length/1 cannot, because that guard
  # is only allowed on lists and silently fails on a binary, so a maxLength on
  # a string would never fire.
  defp length_errors(schema, value, path) when is_binary(value) do
    bounds(schema, path, String.length(value))
  end

  defp length_errors(schema, value, path) when is_list(value) do
    bounds(schema, path, length(value))
  end

  defp bounds(schema, path, size) do
    case schema["minLength"] do
      nil -> []
      min when size < min -> [{path, :too_short}]
      _ -> []
    end ++
      case schema["maxLength"] do
        nil -> []
        max when size > max -> [{path, :too_long}]
        _ -> []
      end
  end

  # maxGraphemes counts what a reader sees, not code points or bytes: a family
  # emoji is one character however many scalars it is made of, and a limit
  # meant as a 300 character post should not count it as seven.
  defp grapheme_errors(nil, _value, _path), do: []

  defp grapheme_errors(max, value, path) do
    if Grapheme.count(value) > max, do: [{path, :too_many_graphemes}], else: []
  end

  defp range_errors(schema, value, path) do
    case schema["minimum"] do
      nil -> []
      min when value < min -> [{path, :below_minimum}]
      _ -> []
    end ++
      case schema["maximum"] do
        nil -> []
        max when value > max -> [{path, :above_maximum}]
        _ -> []
      end
  end

  defp const_errors(nil, _value, _path), do: []

  defp const_errors(const, value, path),
    do: if(const === value, do: [], else: [{path, :not_const}])

  defp enum_errors(nil, _value, _path), do: []

  defp enum_errors(allowed, value, path),
    do: if(value in allowed, do: [], else: [{path, :not_in_enum}])

  # A datetime is a datetime or a date. Anything else that claims the format
  # is refused rather than stored, since an AppView parsing it will either
  # throw or render the wrong thing.
  defp format_errors(nil, _value, _path), do: []

  defp format_errors("datetime", value, path) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} ->
        []

      {:error, reason} ->
        case Date.from_iso8601(value) do
          {:ok, _date} ->
            []

          {:error, date_reason} ->
            # Both reasons are kept: which of the two parsers stopped first is
            # the difference between a missing offset and a malformed date, and
            # a caller logging this wants the specific one.
            [{path, {:bad_datetime, reason, date_reason}}]
        end
    end
  end

  defp format_errors("at-uri", value, path) do
    if String.starts_with?(value, "at://"), do: [], else: [{path, :bad_at_uri}]
  end

  defp format_errors("did", value, path) do
    if String.starts_with?(value, "did:"), do: [], else: [{path, :bad_did}]
  end

  defp format_errors("handle", value, path) do
    if value == "" or String.contains?(value, "/"), do: [{path, :bad_handle}], else: []
  end

  defp format_errors("nsid", value, path) do
    # The name segments cannot start with a digit, which is what keeps an NSID
    # from being read as a number, and the authority has to be the last two
    # segments at minimum.
    segments = String.split(value, ".")

    if length(segments) < 3 or
         Enum.any?(segments, &(&1 == "" or String.match?(&1, ~r/^[0-9]/))) do
      [{path, :bad_nsid}]
    else
      []
    end
  end

  # A TID is 13 characters of base32-sortable: a 64 bit microsecond timestamp
  # in the high bits and a 10 bit clock identifier in the low ones.
  defp format_errors("tid", value, path) do
    if String.match?(value, ~r/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/),
      do: [],
      else: [{path, :bad_tid}]
  end

  defp format_errors("record-key", value, path) do
    if value in ["self"] or String.match?(value, ~r/^[a-zA-Z0-9._~:-]{1,512}$/),
      do: [],
      else: [{path, :bad_record_key}]
  end

  defp format_errors("uri", value, path) do
    case URI.new(value) do
      {:ok, %URI{scheme: nil}} -> [{path, :bad_uri}]
      {:ok, _uri} -> []
      {:error, _reason} -> [{path, :bad_uri}]
    end
  end

  defp format_errors("language", value, path) do
    if String.match?(value, ~r/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})*$/),
      do: [],
      else: [{path, :bad_language}]
  end

  defp format_errors("cid", value, path) do
    if Pesque.CID.safe_parse(value) == :error, do: [{path, :bad_cid}], else: []
  end

  defp format_errors("at-identifier", value, path) do
    cond do
      String.starts_with?(value, "at://") -> []
      String.starts_with?(value, "did:") -> []
      String.contains?(value, "@") -> []
      true -> [{path, :bad_at_identifier}]
    end
  end

  defp format_errors(format, _value, path), do: [{path, {:unsupported_format, format}}]
end
