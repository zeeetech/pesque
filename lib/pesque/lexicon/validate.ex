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
  `object` (with `required`, `nullable`, `properties`), `array` (with `items`,
  `minLength`, `maxLength`), `string` (with `format`, `enum`, `const`,
  `minLength`, `maxLength`, `maxGraphemes`), `integer` (`minimum`, `maximum`,
  `const`), `boolean`, `float`, `number`, `unknown`, `bytes`, `cid-link`,
  `blob`, `token`, `ref` and `union`.

  A field the lexicon does not declare is ignored, not refused. The
  specification says unexpected fields in otherwise conforming data should be
  treated at worst as warnings, and a record type a newer lexicon added a field
  to has to keep validating against the copy this server holds.

  A string's `maxLength` is counted in UTF-8 bytes, which is the unit the
  specification uses, so the check is `byte_size/1` and a value already over it
  is refused before its grapheme count is taken. `maxGraphemes` is the separate
  rule for what a reader sees.

  `bytes`, `cid-link`, `blob` and `token` are accepted on their shape rather
  than parsed: a `$link` that is not a CID and a `$bytes` that is not base64 are
  turned away by `Pesque.Lexicon.from_json/1`, which is what turns a record into
  what the encoder accepts. What the lexicon *states* about them is checked here
  anyway, because a bound nobody enforces is not a bound: `bytes` against
  `maxLength`, `blob` against `maxSize` and `accept`. A blob's `size` is the
  client's own claim about bytes this server cannot see from the record, so that
  check verifies the claim rather than the blob; the authoritative size is
  enforced where the bytes are read, in `uploadBlob`.

  A `ref` or a union member that cannot be resolved, and any node underneath
  one, is skipped rather than failed. A broken cross-reference in someone's
  lexicon should not make their server refuse every write.
  """

  @doc "Validates a value against a lexicon definition."
  @spec validate(map() | nil, term()) :: :ok | {:error, [{[term()], atom() | tuple()}]}
  def validate(nil, _value), do: :ok
  def validate(schema, value), do: errors(schema, value, []) |> Enum.reverse() |> result()

  defp result([]), do: :ok
  defp result(errors), do: {:error, errors}

  # Only the declared properties are looked at. The lexicon says nothing about
  # whether an object tolerates a field it does not name, and the answer the
  # specification gives is to ignore one: a record type a newer lexicon added a
  # field to has to keep validating against the older copy held here, or every
  # client on the newer lexicon gets a 400.
  defp errors(%{"type" => "object"} = schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", {})
    nullable = nullable(schema)

    Enum.flat_map(schema["required"] || [], fn field ->
      if Map.has_key?(value, field) and not is_nil(value[field]),
        do: [],
        else: [{path ++ [field], :required}]
    end) ++
      errors_in(value, properties, path, nullable)
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
      string_length_errors(schema, value, path)
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

  # The $type names which member of the union the value is, and the value is
  # checked against that member's schema, which the registry resolved and
  # attached under "variants". Without it a union body went unchecked: the $type
  # was a bare NSID nothing here could look up, and every field under it was
  # accepted.
  #
  # A member this server holds no schema for is accepted on its name alone,
  # which is the same degradation an unresolvable ref gets anywhere else.
  #
  # A union is open unless it says closed: the spec has implementations stay
  # permissive in case they do not have the most recent lexicon, and a "$type"
  # that no ref names is a shape a future lexicon may have added.
  defp errors(%{"type" => "union"} = schema, value, path) when is_map(value) do
    allowed = [schema["ref"] | Map.get(schema, "refs", [])] |> Enum.reject(&is_nil/1)

    case value["$type"] do
      nil ->
        [{path, :missing_type}]

      type ->
        # #name is a reference within this same document, so it resolves against
        # the defs attached here; a bare NSID needs the registry, which this
        # function deliberately does not have, so it is looked up in the
        # variants the registry attached and taken on its name when it is not
        # there.
        case resolve(schema, allowed, type) do
          {:ok, target} -> errors(target, value, path)
          :foreign -> []
          :unknown -> if(schema["closed"] == true, do: [{path, :unknown_type}], else: [])
        end
    end
  end

  defp errors(%{"type" => "union"}, _value, path), do: [{path, :expected_object}]

  defp errors(%{"type" => "ref"}, _value, _path), do: []

  # What the lexicon states about bytes is a length, and it is measurable: the
  # value is either a decoded binary or the base64 the client sent. Skipping the
  # bound would let a value of any size through on the strength of the lexicon
  # asking for one.
  defp errors(%{"type" => "bytes"} = schema, value, path) when is_binary(value),
    do: bounds(schema, path, byte_size(value))

  defp errors(%{"type" => "bytes"} = schema, value, path) when is_map(value) do
    # A record reaches this module before from_json/1 has run, so a $bytes here
    # is still the base64 the client sent. The bound is in bytes, so it is
    # measured on what that decodes to rather than on the encoding of it.
    with false <- is_struct(value),
         {:ok, b64} when is_binary(b64) <- Map.fetch(value, "$bytes"),
         {:ok, data} <- Base.decode64(b64) do
      bounds(schema, path, byte_size(data))
    else
      _ -> []
    end
  end

  defp errors(%{"type" => "bytes"}, _value, _path), do: []

  # A blob's size is the number the client declared alongside its ref, which is
  # the only size this record carries: the bytes themselves went to uploadBlob
  # and are not here to measure. So this checks the claim against what the
  # lexicon allows, and uploadBlob is where the real size is enforced.
  defp errors(%{"type" => "blob"} = schema, value, path) when is_map(value) do
    # A struct is a map to is_map/1 but not to [], and a blob already parsed into
    # one carries no size or mimeType to check.
    if is_struct(value) do
      []
    else
      blob_size_errors(schema["maxSize"], value["size"], path) ++
        accept_errors(schema["accept"], value["mimeType"], path)
    end
  end

  defp errors(%{"type" => "blob"}, _value, _path), do: []

  # cid-link and token state no bound the lexicon gives this module a way to
  # check, so they are accepted for what they are.
  defp errors(%{"type" => type}, _value, _path) when type in ["cid-link", "token"], do: []

  defp errors(_def, _value, path), do: [{path, :unrecognized_definition}]

  # The declared items are always checked.
  defp item_errors(nil, _value, _path), do: []

  defp item_errors(items, value, path) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} -> errors(items, element, path ++ [index]) end)
  end

  # The spec models nullable as an array of property names on the object, and has
  # no boolean form of it. Anything else a lexicon puts under the key is not a
  # list of names, and a schema this module cannot read is not one it should
  # crash a write over.
  defp nullable(schema) do
    case Map.get(schema, "nullable") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # A null on a field the object lists as nullable is a legal value, so it is
  # left alone rather than handed to the type check that would refuse it. The
  # same null on any other field is handed over as before.
  defp errors_in(value, properties, path, nullable) do
    Enum.flat_map(properties, fn {key, schema} ->
      case Map.fetch(value, key) do
        {:ok, nil} -> if(key in nullable, do: [], else: errors(schema, nil, path ++ [key]))
        {:ok, nested} -> errors(schema, nested, path ++ [key])
        :error -> []
      end
    end)
  end

  # The value's $type is compared against the refs this union declared, so a $type
  # naming none of them is not a member at all. What happens then depends on the
  # union: a closed one refuses it, an open one has nothing to check it against.
  defp resolve(schema, allowed, type) do
    {target, fragment} =
      case String.split(type, "#", parts: 2) do
        ["#" <> name] -> {"", name}
        [nsid] -> {nsid, nil}
        [nsid, name] -> {nsid, name}
      end

    cond do
      # The whole string first, fragment included. A ref a lexicon declares as
      # "com.atproto.label.defs#selfLabels" is matched by a value whose $type is
      # that exact string, and splitting first would look for the fragment in
      # the wrong document's defs.
      type in allowed ->
        variant(schema, type, fragment)

      target == "" ->
        :unknown

      # A $type that names an NSID with a fragment matches a ref carrying that
      # same NSID, since that is what the lexicon declaring the ref meant: a
      # facet feature lists "#link", and the value arrives as
      # app.bsky.richtext.facet#link. Matching only the whole string would
      # refuse every one of those.
      is_nil(fragment) ->
        if target in allowed, do: variant(schema, target, nil), else: :unknown

      target in allowed ->
        variant(schema, target, fragment)

      ("#" <> fragment) in allowed ->
        variant(schema, "#" <> fragment, fragment)

      true ->
        :unknown
    end
  end

  # The schema the registry resolved this ref to, keyed by the ref as the
  # lexicon wrote it. A node that came from anywhere else (a lexicon this server
  # does not hold, or a hand-written test schema) has none, so the defs attached
  # to the node are the fallback.
  defp variant(schema, ref, fragment) do
    case Map.get(Map.get(schema, "variants", %{}), ref) do
      nil -> local_def(schema, fragment)
      target -> {:ok, target}
    end
  end

  # The def attached to the node, for a schema that arrived without resolved
  # variants behind it. One naming a def this document does not have is treated
  # as foreign rather than unknown: it is still inside a declared ref, and
  # refusing it would fail records against the repository's own schema.
  defp local_def(schema, fragment) do
    case Map.get(Map.get(schema, "defs", %{}), fragment) do
      nil -> :foreign
      target -> {:ok, target}
    end
  end

  # Split by what length means: a string is measured in UTF-8 bytes and an array
  # in elements. A single guard using length/1 cannot, because that guard is
  # only allowed on lists and silently fails on a binary, so a maxLength on a
  # string would never fire.
  #
  # The byte count is the spec's unit and the only one of the three that is
  # O(1). An over-long value is refused on it before its grapheme count is
  # taken, which matters on a multi-megabyte body: without the short circuit an
  # oversized post was walked in full inside the writer process only to be
  # turned away.
  defp string_length_errors(schema, value, path) do
    case bounds(schema, path, byte_size(value)) do
      [{_, :too_long}] = too_long -> too_long
      size_errors -> size_errors ++ grapheme_errors(schema["maxGraphemes"], value, path)
    end
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

  # A blob declares its size as an integer, so a size that is not one cannot be
  # compared and is not this check's business to rule on.
  defp blob_size_errors(nil, _size, _path), do: []

  defp blob_size_errors(max, size, path) when is_integer(size) and size > max,
    do: [{path, :too_large}]

  defp blob_size_errors(_max, _size, _path), do: []

  # accept is a list of mime patterns where "*" stands for any part of the
  # type/subtype pair, which is how a lexicon says "any image".
  defp accept_errors(nil, _mime, _path), do: []

  defp accept_errors(accepted, mime, path) when is_binary(mime) do
    if Enum.any?(List.wrap(accepted), &accepts?(&1, mime)),
      do: [],
      else: [{path, :bad_mime_type}]
  end

  defp accept_errors(_accepted, _mime, _path), do: []

  defp accepts?(pattern, mime) when is_binary(pattern) do
    cond do
      pattern == "*/*" ->
        true

      pattern == "*" ->
        String.contains?(mime, "/")

      String.ends_with?(pattern, "/*") ->
        String.starts_with?(mime, String.trim_trailing(pattern, "*"))

      String.starts_with?(pattern, "*/") ->
        String.ends_with?(mime, String.trim_leading(pattern, "*"))

      true ->
        pattern == mime
    end
  end

  defp accepts?(_pattern, _mime), do: false

  # maxGraphemes counts what a reader sees, not code points or bytes: a family
  # emoji is one character however many scalars it is made of, and a limit
  # meant as a 300 character post should not count it as seven. `String.length/1`
  # counts grapheme clusters, which is that unit.
  defp grapheme_errors(nil, _value, _path), do: []

  defp grapheme_errors(max, value, path) do
    if String.length(value) > max, do: [{path, :too_many_graphemes}], else: []
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
