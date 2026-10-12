defmodule Pesque.OAuth.Permission do
  @moduledoc """
  One atproto permission: the scope-string grammar, the coverage question,
  and the one line the consent page shows the account holder.

  Pure core: strings and structs in, booleans and strings out. No clock, no
  database, no network. The required side of a coverage question is always
  built here by the `*_required` builders and never carries a wildcard; only
  the granted side may.

  The grammar follows the atproto permission specification: a resource name,
  an optional positional parameter, and optional query parameters, all within
  printable non-whitespace ASCII. The errors are tagged and internal: the PAR
  boundary (`Pesque.OAuth.Scopes.validate/1`) wraps them into one
  `{:invalid_scope, scope}` answer that names the offending string.
  """

  alias Pesque.OAuth.Permission

  @enforce_keys [:resource]
  defstruct [
    :resource,
    # rpc and include: "*" or a did:web/did:plc reference with its fragment.
    :aud,
    # account: :email | :repo. identity: :handle | :*.
    :attr,
    # include: the permission set's NSID.
    :nsid,
    # repo: the collections, one per value, or ["*"].
    collection: [],
    # repo: nil (every action) or a list of actions. account: :read | :manage.
    action: nil,
    # rpc: the methods, one per value, or ["*"]. The required side is
    # one-element, or the :any atom for the method-unscoped form.
    lxm: [],
    # blob: lowercased MIME patterns, one per value.
    accept: []
  ]

  @type t :: %__MODULE__{}
  @type resource ::
          :atproto
          | :transition_generic
          | :transition_chat
          | :transition_email
          | :repo
          | :rpc
          | :blob
          | :account
          | :identity
          | :include
  @type action :: :create | :update | :delete

  # The same shape Pesque.ServiceAuth checks audiences against, with the
  # fragment required: a permission naming a service names the service by its
  # #serviceId, and "*" is the only other audience a scope string may carry.
  @aud_regex ~r/\Adid:(web|plc):[a-zA-Z0-9._%\-]+(:[a-zA-Z0-9._\-]+)*#[a-zA-Z0-9._\-]+\z/

  # The same shape Pesque.ServiceAuth and Pesque.Entryway.Proxy check method
  # names against.
  @nsid_regex ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/

  @repo_actions %{"create" => :create, "update" => :update, "delete" => :delete}
  @account_attrs %{"email" => :email, "repo" => :repo}
  @account_actions %{"read" => :read, "manage" => :manage}
  @identity_attrs %{"handle" => :handle, "*" => :*}

  @parse_resources ~w(atproto transition repo rpc blob account identity include)

  @doc "Whether `scope` is a well-formed, understood permission scope string."
  @spec parse_scope(term()) :: {:ok, t()} | {:error, term()}
  def parse_scope(scope) when is_binary(scope) do
    with {:ok, _} <- charset(scope),
         {:ok, resource, positional, params} <- split(scope),
         {:ok, resource, positional, params} <- decode(resource, positional, params) do
      semantics(resource, positional, params)
    end
  end

  def parse_scope(_scope), do: {:error, :invalid_syntax}

  # 1. Every byte printable, non-whitespace ASCII.
  defp charset(<<byte, rest::binary>>) when byte in 0x21..0x7E, do: charset(rest)
  defp charset(<<_byte, _rest::binary>>), do: {:error, :invalid_characters}
  defp charset(<<>>), do: {:ok, :parsed}

  # 2. The first "?" separates the query; in the head, the first ":" separates
  # resource and positional. The positional may hold any allowed byte except
  # "?": further colons, "#", ".", "&" and "=" are all legal there.
  defp split(scope) do
    case String.split(scope, "?", parts: 2) do
      [head, query] ->
        with {:ok, resource, positional} <- resource_and_positional(head),
             {:ok, params} <- query_params(query) do
          {:ok, resource, positional, params}
        end

      [head] ->
        with {:ok, resource, positional} <- resource_and_positional(head) do
          {:ok, resource, positional, []}
        end
    end
  end

  defp resource_and_positional(head) do
    case String.split(head, ":", parts: 2) do
      # An empty positional is a missing one: `repo:` says nothing.
      [resource, ""] -> {:ok, resource, :none}
      [resource, positional] -> {:ok, resource, {:some, positional}}
      [resource] -> {:ok, resource, :none}
    end
  end

  # An empty query is an empty parameter list, so `identity:*?` is valid. A
  # segment with no name, or with no "=" at all, is not a parameter. An empty
  # segment (a stray "&") carries nothing and is dropped, which is what keeps
  # `resource:&` a semantics question and not a syntax one.
  defp query_params(""), do: {:ok, []}

  defp query_params(query) do
    query
    |> String.split("&")
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case String.split(segment, "=", parts: 2) do
        [name, value] when name != "" -> {:cont, {:ok, [{name, value} | acc]}}
        _other -> {:halt, {:error, :invalid_syntax}}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      error -> error
    end
  end

  # 3. Percent-decoding of the positional and of every parameter name and
  # value. Hand-rolled because URI.decode_www_form/1 applies form semantics
  # and would turn "+" into a space. Raw bytes pass through untouched.
  defp decode(resource, positional, params) do
    with {:ok, positional} <- decode_part(positional),
         {:ok, params} <- decode_params(params) do
      {:ok, resource, positional, params}
    end
  end

  defp decode_part(:none), do: {:ok, :none}

  defp decode_part({:some, value}) do
    case decode_percent(value) do
      {:ok, decoded} -> {:ok, {:some, decoded}}
      error -> error
    end
  end

  defp decode_params([]), do: {:ok, []}

  defp decode_params([{name, value} | rest]) do
    with {:ok, name} <- decode_percent(name),
         {:ok, value} <- decode_percent(value),
         {:ok, decoded} <- decode_params(rest) do
      {:ok, [{name, value} | decoded]}
    end
  end

  defguardp is_hex_digit(byte)
            when byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp decode_percent(<<>>), do: {:ok, ""}

  defp decode_percent(<<?%, hi, lo, rest::binary>>) when is_hex_digit(hi) and is_hex_digit(lo) do
    case decode_percent(rest) do
      {:ok, decoded} -> {:ok, <<hex_value(hi) * 16 + hex_value(lo)>> <> decoded}
      error -> error
    end
  end

  defp decode_percent(<<?%, _hi, _lo, _rest::binary>>), do: {:error, :invalid_syntax}
  defp decode_percent(<<?%, _rest::binary>>), do: {:error, :invalid_syntax}

  defp decode_percent(<<byte, rest::binary>>) do
    case decode_percent(rest) do
      {:ok, decoded} -> {:ok, <<byte>> <> decoded}
      error -> error
    end
  end

  defp hex_value(byte) when byte in ?0..?9, do: byte - ?0
  defp hex_value(byte) when byte in ?a..?f, do: byte - ?a + 10
  defp hex_value(byte) when byte in ?A..?F, do: byte - ?A + 10

  # 4. The resource's own semantics. An unknown resource is refused before
  # anything about its parameters is looked at.

  defp semantics(resource, _positional, _params) when resource not in @parse_resources do
    {:error, {:unknown_resource, resource}}
  end

  # The bare words take no positional and no parameters. `transition:` takes
  # exactly one of the three known positionals and nothing else.
  defp semantics("atproto", :none, []), do: {:ok, %Permission{resource: :atproto}}

  defp semantics("atproto", {:some, _positional}, _params),
    do: {:error, {:bad_positional, :atproto}}

  defp semantics("atproto", :none, [{name, _value} | _rest]), do: {:error, {:bad_parameter, name}}

  defp semantics("transition", {:some, "generic"}, []),
    do: {:ok, %Permission{resource: :transition_generic}}

  defp semantics("transition", {:some, "chat.bsky"}, []),
    do: {:ok, %Permission{resource: :transition_chat}}

  defp semantics("transition", {:some, "email"}, []),
    do: {:ok, %Permission{resource: :transition_email}}

  defp semantics("transition", {:some, positional}, _params),
    do: {:error, {:unknown_scope, "transition:" <> positional}}

  defp semantics("transition", :none, [{name, _value} | _rest]),
    do: {:error, {:bad_parameter, name}}

  defp semantics("transition", :none, []), do: {:error, {:bad_positional, :transition}}

  defp semantics("repo", positional, params) do
    with :ok <- known_params(params, ["collection", "action"]),
         {:ok, collections} <- positional_values(positional, params, "collection", :repo),
         :ok <- wildcards(collections),
         :ok <- nsid_values(collections, "collection"),
         {:ok, action} <- repo_action(params) do
      {:ok, %Permission{resource: :repo, collection: collections, action: action}}
    end
  end

  defp semantics("rpc", positional, params) do
    with :ok <- known_params(params, ["lxm", "aud"]),
         {:ok, lxms} <- positional_values(positional, params, "lxm", :rpc),
         :ok <- wildcards(lxms),
         :ok <- nsid_values(lxms, "lxm"),
         {:ok, aud} <- required_param(params, "aud", &(&1 == "*" or aud_ref?(&1))),
         :ok <- both_wildcards(lxms, aud) do
      {:ok, %Permission{resource: :rpc, lxm: lxms, aud: aud}}
    end
  end

  defp semantics("blob", positional, params) do
    with :ok <- known_params(params, ["accept"]),
         {:ok, values} <- positional_values(positional, params, "accept", :blob),
         {:ok, patterns} <- blob_patterns(values) do
      {:ok, %Permission{resource: :blob, accept: patterns}}
    end
  end

  defp semantics("account", positional, params) do
    with :ok <- known_params(params, ["attr", "action"]),
         {:ok, values} <- positional_values(positional, params, "attr", :account),
         {:ok, [attr]} <- single_value(values, "attr"),
         {:ok, attr} <- account_attr(attr),
         {:ok, action} <- optional_param(params, "action", &Map.has_key?(@account_actions, &1)),
         {:ok, action} <- account_action(action) do
      {:ok, %Permission{resource: :account, attr: attr, action: action}}
    end
  end

  defp semantics("identity", positional, params) do
    with :ok <- known_params(params, ["attr"]),
         {:ok, values} <- positional_values(positional, params, "attr", :identity),
         {:ok, [attr]} <- single_value(values, "attr"),
         {:ok, attr} <- mapped(attr, @identity_attrs, "attr") do
      {:ok, %Permission{resource: :identity, attr: attr}}
    end
  end

  defp semantics("include", :none, _params), do: {:error, {:bad_positional, :include}}

  defp semantics("include", {:some, nsid}, params) do
    with :ok <- known_params(params, ["aud"]),
         :ok <- wildcards([nsid]),
         true <- Regex.match?(@nsid_regex, nsid) || {:error, {:bad_positional, :include}},
         {:ok, aud} <- optional_param(params, "aud", &(&1 == "*" or aud_ref?(&1))) do
      {:ok, %Permission{resource: :include, nsid: nsid, aud: aud}}
    end
  end

  # A parameter is either the positional value or one of an array, never both:
  # `repo:com.example.record?collection=com.example.other` says two different
  # things and is refused rather than resolved.
  defp positional_values({:some, value}, params, name, resource) do
    if Enum.any?(params, fn {param_name, _value} -> param_name == name end) do
      {:error, {:bad_positional, resource}}
    else
      {:ok, [value]}
    end
  end

  defp positional_values(:none, params, name, resource) do
    values = for {param_name, value} <- params, param_name == name, do: value

    if values == [], do: {:error, {:bad_positional, resource}}, else: {:ok, values}
  end

  defp single_value([value], _name), do: {:ok, [value]}
  defp single_value(_values, name), do: {:error, {:bad_parameter, name}}

  defp mapped(value, map, name) do
    case Map.fetch(map, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:bad_parameter, name}}
    end
  end

  # One parameter name the resource does not know is refused by name, so a
  # caller that misspelled a parameter learns which one.
  defp known_params(params, allowed) do
    case Enum.find(params, fn {name, _value} -> name not in allowed end) do
      nil -> :ok
      {name, _value} -> {:error, {:bad_parameter, name}}
    end
  end

  # A wildcard is the whole value or nothing: a partial wildcard names nothing
  # real and would read as narrower than it is.
  defp wildcards(values) do
    if Enum.any?(values, fn value -> String.contains?(value, "*") and value != "*" end) do
      {:error, :wildcard_not_allowed}
    else
      :ok
    end
  end

  defp nsid_values(values, name) do
    if Enum.all?(values, &(&1 == "*" or Regex.match?(@nsid_regex, &1))),
      do: :ok,
      else: {:error, {:bad_parameter, name}}
  end

  defp repo_action(params) do
    values = for {"action", value} <- params, do: value

    cond do
      values == [] ->
        {:ok, nil}

      Enum.all?(values, &Map.has_key?(@repo_actions, &1)) and
          length(values) == length(Enum.uniq(values)) ->
        {:ok, Enum.map(values, &Map.fetch!(@repo_actions, &1))}

      true ->
        {:error, {:bad_parameter, "action"}}
    end
  end

  # A single-value parameter: given twice, or with a value the resource does
  # not know, is refused by name.
  defp optional_param(params, name, valid?) do
    values = for {param_name, value} <- params, param_name == name, do: value

    case values do
      [] -> {:ok, nil}
      [value] -> if valid?.(value), do: {:ok, value}, else: {:error, {:bad_parameter, name}}
      _other -> {:error, {:bad_parameter, name}}
    end
  end

  # The rpc audience is required in the scope-string form: a permission that
  # names a method but no service names nothing real.
  defp required_param(params, name, valid?) do
    case optional_param(params, name, valid?) do
      {:ok, nil} -> {:error, :missing_aud}
      other -> other
    end
  end

  # The rpc wildcard pairs with a concrete lxm, never with a wildcard one.
  defp both_wildcards(lxms, "*") do
    if lxms == ["*"], do: {:error, :both_rpc_wildcards}, else: :ok
  end

  defp both_wildcards(_lxms, _aud), do: :ok

  defp aud_ref?(aud), do: Regex.match?(@aud_regex, aud)

  defp account_attr("*"), do: {:error, :wildcard_not_allowed}
  defp account_attr(value), do: mapped(value, @account_attrs, "attr")

  defp account_action(nil), do: {:ok, :read}
  defp account_action(value), do: {:ok, Map.fetch!(@account_actions, value)}

  defp blob_patterns(values) do
    patterns = Enum.map(values, &String.downcase/1)

    # MIME types are case-insensitive, so patterns normalize to lowercase; the
    # grammar's case sensitivity governs resource names, not MIME semantics.
    if Enum.all?(patterns, &mime_pattern?/1),
      do: {:ok, patterns},
      else: {:error, {:bad_parameter, "accept"}}
  end

  # "type/subtype" where each side is a MIME token or "*".
  defp mime_pattern?(value) do
    case String.split(value, "/", parts: 2) do
      [type, subtype] -> mime_token?(type) and mime_token?(subtype)
      _single -> false
    end
  end

  defguardp is_mime_token_byte(byte)
            when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or
                   byte in ~c"!#$%&'*+.^_`|~-"

  defp mime_token?("*"), do: true
  defp mime_token?(<<>>), do: true

  defp mime_token?(<<byte, rest::binary>>) when is_mime_token_byte(byte),
    do: mime_token?(rest)

  defp mime_token?(_other), do: false

  @doc """
  The canonical scope string for a permission.

  One value rides in the positional part, several ride as parameters. "#" in a
  parameter value is emitted percent-encoded; positional values never need it.
  The round-trip property holds: `parse_scope(serialize(permission))` is
  `{:ok, permission}` for every valid permission.
  """
  @spec serialize(t()) :: String.t()
  def serialize(%Permission{resource: :atproto}), do: "atproto"
  def serialize(%Permission{resource: :transition_generic}), do: "transition:generic"
  def serialize(%Permission{resource: :transition_chat}), do: "transition:chat.bsky"
  def serialize(%Permission{resource: :transition_email}), do: "transition:email"

  def serialize(%Permission{resource: :repo, collection: [collection], action: action}) do
    "repo:" <> collection <> params(action_params(action))
  end

  def serialize(%Permission{resource: :repo, collection: collections, action: action}) do
    "repo" <> params(Enum.map(collections, &{"collection", &1}) ++ action_params(action))
  end

  # The method-unscoped form is asked for as the wildcard grant it takes, so
  # the canonical string is the wildcard spelling.
  def serialize(%Permission{resource: :rpc, lxm: :any, aud: aud}) do
    "rpc" <> params([{"lxm", "*"}, {"aud", encode_value(aud)}])
  end

  def serialize(%Permission{resource: :rpc, lxm: [lxm], aud: aud}) do
    "rpc:" <> lxm <> params([{"aud", encode_value(aud)}])
  end

  def serialize(%Permission{resource: :rpc, lxm: lxms, aud: aud}) do
    "rpc" <> params(Enum.map(lxms, &{"lxm", &1}) ++ [{"aud", encode_value(aud)}])
  end

  def serialize(%Permission{resource: :blob, accept: [pattern]}), do: "blob:" <> pattern

  def serialize(%Permission{resource: :blob, accept: patterns}) do
    "blob" <> params(Enum.map(patterns, &{"accept", &1}))
  end

  def serialize(%Permission{resource: :account, attr: attr, action: :manage}) do
    "account:" <> attr_name(attr) <> params([{"action", "manage"}])
  end

  # read is the default and is omitted, the way the parser reads its absence.
  def serialize(%Permission{resource: :account, attr: attr}), do: "account:" <> attr_name(attr)

  def serialize(%Permission{resource: :identity, attr: attr}), do: "identity:" <> attr_name(attr)

  def serialize(%Permission{resource: :include, nsid: nsid, aud: nil}), do: "include:" <> nsid

  def serialize(%Permission{resource: :include, nsid: nsid, aud: aud}) do
    "include:" <> nsid <> params([{"aud", encode_value(aud)}])
  end

  defp action_params(nil), do: []

  defp action_params(actions) do
    Enum.map(actions, fn action -> {"action", Atom.to_string(action)} end)
  end

  defp params([]), do: ""

  defp params(pairs) do
    "?" <> Enum.map_join(pairs, "&", fn {name, value} -> name <> "=" <> value end)
  end

  # Only "#" has to come back through an escape: it is legal raw in a
  # parameter value but is a fragment marker to everything downstream that
  # reads a DID reference out of one.
  defp encode_value(value), do: String.replace(value, "#", "%23")

  defp attr_name(:email), do: "email"
  defp attr_name(:repo), do: "repo"
  defp attr_name(:handle), do: "handle"
  defp attr_name(:*), do: "*"

  @doc """
  The lenient parser for permission-set members and stored grants.

  Every malformed or uninterpretable member is :skip and never an error: the
  specification has the server ignore declarations it does not understand
  rather than refuse the set. Blob, account and identity cannot appear in a
  set, and a wildcard is meaningless inside one.
  """
  @spec from_set_member(map()) :: {:ok, t()} | :skip
  def from_set_member(%{"type" => "permission", "resource" => "repo"} = member) do
    with :ok <- set_keys(member),
         {:ok, collections} <- set_collections(member),
         {:ok, action} <- set_action(Map.get(member, "action")) do
      {:ok, %Permission{resource: :repo, collection: collections, action: action}}
    else
      _error -> :skip
    end
  end

  def from_set_member(%{"type" => "permission", "resource" => "rpc"} = member) do
    with :ok <- set_keys(member),
         {:ok, lxms} <- set_lxms(member),
         {:ok, aud} <- set_aud(member) do
      {:ok, %Permission{resource: :rpc, lxm: lxms, aud: aud}}
    else
      _error -> :skip
    end
  end

  def from_set_member(_member), do: :skip

  @set_keys ~w(type resource collection action lxm aud inheritAud)

  defp set_keys(member) do
    if Enum.all?(Map.keys(member), &(&1 in @set_keys)), do: :ok, else: {:error, :unknown_key}
  end

  defp set_collections(%{"collection" => collections})
       when is_list(collections) and collections != [] do
    if Enum.all?(collections, &(is_binary(&1) and Regex.match?(@nsid_regex, &1))),
      do: {:ok, collections},
      else: {:error, :bad_collection}
  end

  defp set_collections(_member), do: {:error, :bad_collection}

  defp set_action(nil), do: {:ok, nil}

  defp set_action(actions) when is_list(actions) do
    if Enum.all?(actions, &(is_binary(&1) and Map.has_key?(@repo_actions, &1))) and
         length(actions) == length(Enum.uniq(actions)) do
      {:ok, Enum.map(actions, &Map.fetch!(@repo_actions, &1))}
    else
      {:error, :bad_action}
    end
  end

  defp set_action(_actions), do: {:error, :bad_action}

  defp set_lxms(%{"lxm" => lxms}) when is_list(lxms) and lxms != [] do
    if Enum.all?(lxms, &(is_binary(&1) and Regex.match?(@nsid_regex, &1))),
      do: {:ok, lxms},
      else: {:error, :bad_lxm}
  end

  defp set_lxms(_member), do: {:error, :bad_lxm}

  # Inside a set the audience is "*" or inherited from the include that
  # invoked it: a DID reference there would grant a service the set's own
  # namespace never named.
  defp set_aud(member) do
    aud = Map.get(member, "aud")
    inherit = Map.get(member, "inheritAud", false)

    cond do
      aud == "*" and not Map.has_key?(member, "inheritAud") -> {:ok, "*"}
      is_nil(aud) and inherit == true -> {:ok, nil}
      true -> {:error, :bad_aud}
    end
  end

  @doc "The inverse of `from_set_member/1`, for the stored grants column."
  @spec to_set_member(t()) :: map()
  def to_set_member(%Permission{resource: :repo, collection: collections, action: action}) do
    member = %{"type" => "permission", "resource" => "repo", "collection" => collections}
    put_member_action(member, action)
  end

  def to_set_member(%Permission{resource: :rpc, lxm: lxms, aud: aud}) do
    member = %{"type" => "permission", "resource" => "rpc", "lxm" => lxms}
    if aud, do: Map.put(member, "aud", aud), else: member
  end

  def to_set_member(%Permission{resource: :blob, accept: accept}) do
    %{"type" => "permission", "resource" => "blob", "accept" => accept}
  end

  def to_set_member(%Permission{resource: :account, attr: attr, action: action}) do
    %{
      "type" => "permission",
      "resource" => "account",
      "attr" => attr_name(attr),
      "action" => [Atom.to_string(action)]
    }
  end

  def to_set_member(%Permission{resource: :identity, attr: attr}) do
    %{"type" => "permission", "resource" => "identity", "attr" => attr_name(attr)}
  end

  def to_set_member(%Permission{resource: :include, nsid: nsid, aud: aud}) do
    member = %{"type" => "permission", "resource" => "include", "nsid" => nsid}
    if aud, do: Map.put(member, "aud", aud), else: member
  end

  # atproto and the transition scopes have no set-member form: expansion
  # replaces them with concrete permissions before anything is stored.
  def to_set_member(%Permission{resource: resource}) do
    %{"type" => "permission", "resource" => Atom.to_string(resource)}
  end

  defp put_member_action(member, nil), do: member

  defp put_member_action(member, actions) do
    Map.put(member, "action", Enum.map(actions, &Atom.to_string/1))
  end

  @doc """
  Whether a granted permission covers a required one.

  The required side is always concrete, built by the `*_required` builders.
  `atproto` covers everything: it is the compatibility grant, the meaning
  every token this server ever issued relies on.
  """
  @spec covers?(t(), t()) :: boolean()
  def covers?(%Permission{resource: :atproto}, _required), do: true

  def covers?(%Permission{resource: :transition_generic}, %Permission{resource: :repo}), do: true

  def covers?(%Permission{resource: :transition_generic}, %Permission{resource: :blob}), do: true

  # The generic transition scope reaches every method but the chat ones, and
  # never the method-unscoped form of getServiceAuth: a token for one
  # endpoint is not a token for every endpoint.
  def covers?(%Permission{resource: :transition_generic}, %Permission{resource: :rpc, lxm: [lxm]})
      when is_binary(lxm),
      do: not String.starts_with?(lxm, "chat.bsky.")

  def covers?(%Permission{resource: :transition_chat}, %Permission{resource: :rpc, lxm: [lxm]})
      when is_binary(lxm),
      do: String.starts_with?(lxm, "chat.bsky.")

  def covers?(
        %Permission{resource: :repo, collection: collections, action: granted},
        %Permission{resource: :repo, collection: [collection], action: required}
      ) do
    ("*" in collections or collection in collections) and
      (is_nil(granted) or Enum.all?(required, &(&1 in granted)))
  end

  # The method-unscoped form (getServiceAuth without an lxm) is covered only
  # by a literal wildcard-lxm grant: a set of named methods never adds up to
  # "any method".
  def covers?(
        %Permission{resource: :rpc, lxm: ["*"], aud: granted_aud},
        %Permission{resource: :rpc, lxm: :any, aud: aud}
      ) do
    granted_aud == "*" or granted_aud == aud
  end

  def covers?(
        %Permission{resource: :rpc, lxm: granted, aud: granted_aud},
        %Permission{resource: :rpc, lxm: [lxm], aud: aud}
      ) do
    ("*" in granted or lxm in granted) and (granted_aud == "*" or granted_aud == aud)
  end

  def covers?(
        %Permission{resource: :blob, accept: patterns},
        %Permission{resource: :blob, accept: [mime]}
      ) do
    Enum.any?(patterns, fn pattern ->
      case String.split(pattern, "/", parts: 2) do
        ["*", "*"] -> true
        ["*", subtype] -> mime_subtype(mime) == subtype
        [type, "*"] -> mime_type(mime) == type
        [type, subtype] -> mime == type <> "/" <> subtype
        _single -> false
      end
    end)
  end

  def covers?(
        %Permission{resource: :account, attr: attr, action: :manage},
        %Permission{resource: :account, attr: attr}
      ),
      do: true

  def covers?(
        %Permission{resource: :account, attr: attr, action: action},
        %Permission{resource: :account, attr: attr, action: action}
      ),
      do: true

  def covers?(%Permission{resource: :identity, attr: attr}, %Permission{
        resource: :identity,
        attr: attr
      }),
      do: true

  def covers?(%Permission{resource: :identity, attr: :*}, %Permission{resource: :identity}),
    do: true

  # include never covers anything directly: expansion replaces it with the
  # concrete permissions before grants reach the plug.
  def covers?(_granted, _required), do: false

  defp mime_type(mime), do: mime |> String.split("/", parts: 2) |> hd()

  defp mime_subtype(mime) do
    case String.split(mime, "/", parts: 2) do
      [_type, subtype] -> subtype
      [_type] -> ""
    end
  end

  @doc "One human sentence for the consent page, per permission."
  @spec describe(t()) :: String.t()
  def describe(%Permission{resource: :atproto}),
    do: "Confirms this app uses the atproto OAuth profile"

  def describe(%Permission{resource: :transition_generic}),
    do:
      "Reads and writes your records, uploads media, calls other services in your name and " <>
        "uses your preferences. This is a broad compatibility grant: it does not include " <>
        "account management, your email address or direct messages"

  def describe(%Permission{resource: :transition_chat}),
    do:
      "Calls the direct message (chat.bsky) API in your name. " <>
        "Needs the generic compatibility grant"

  def describe(%Permission{resource: :transition_email}), do: "Sees your email address"

  def describe(%Permission{resource: :repo, collection: collections, action: actions}) do
    "#{verb_list(actions || [:create, :update, :delete])} records in #{Enum.join(collections, ", ")}"
  end

  def describe(%Permission{resource: :rpc, lxm: lxms, aud: aud}),
    do: "Calls #{Enum.join(lxms, ", ")} in your name#{aud_clause(aud)}"

  def describe(%Permission{resource: :blob, accept: patterns}),
    do: "Uploads media of type #{Enum.join(patterns, ", ")}"

  def describe(%Permission{resource: :account, attr: :email, action: :manage}),
    do: "Sees and changes your email address"

  def describe(%Permission{resource: :account, attr: :email}), do: "Sees your email address"

  def describe(%Permission{resource: :account, attr: :repo, action: :manage}),
    do: "Replaces your whole repository with an uploaded file"

  def describe(%Permission{resource: :account, attr: :repo}),
    do: "Reads your repository status (import needs the manage action)"

  def describe(%Permission{resource: :identity, attr: :handle}), do: "Changes your handle"

  def describe(%Permission{resource: :identity, attr: :*}),
    do: "Changes your handle and your DID document"

  def describe(%Permission{resource: :include, nsid: nsid, aud: aud}),
    do: "Grants the permissions in the #{nsid} set#{aud_clause(aud)}"

  defp aud_clause("*"), do: " on any service"
  defp aud_clause(nil), do: ""
  defp aud_clause(aud), do: " on " <> aud

  # "Create, update and delete" from [:create, :update, :delete].
  defp verb_list(actions) do
    parts = Enum.map(actions, &Atom.to_string/1)
    last = List.last(parts)
    earlier = parts |> Enum.take(length(parts) - 1) |> Enum.join(", ")

    if(earlier == "", do: last, else: earlier <> " and " <> last)
    |> String.capitalize()
  end

  # The requirement builders: the concrete side of a coverage question. No
  # wildcards ever ride on these.

  @doc "The permission one repo write needs, named by its action."
  @spec repo_required(String.t(), [action()]) :: t()
  def repo_required(collection, actions),
    do: %Permission{resource: :repo, collection: [collection], action: actions}

  @doc """
  The permission one rpc call needs.

  `lxm` of `:any` is only for getServiceAuth asked without an lxm parameter:
  a token for every method is a different grant from a token for one.
  """
  @spec rpc_required(:any | String.t(), String.t()) :: t()
  def rpc_required(:any, aud), do: %Permission{resource: :rpc, lxm: :any, aud: aud}
  def rpc_required(lxm, aud), do: %Permission{resource: :rpc, lxm: [lxm], aud: aud}

  @doc "The permission one blob upload needs, lowercased, parameters stripped."
  @spec blob_required(String.t()) :: t()
  def blob_required(media_type) do
    pattern = media_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    %Permission{resource: :blob, accept: [pattern]}
  end

  @doc "The permission one account attribute needs."
  @spec account_required(:email | :repo, :read | :manage) :: t()
  def account_required(attr, action),
    do: %Permission{resource: :account, attr: attr, action: action}

  @doc "The permission one identity change needs."
  @spec identity_required(:handle | :*) :: t()
  def identity_required(:handle), do: %Permission{resource: :identity, attr: :handle}
  def identity_required(:*), do: %Permission{resource: :identity, attr: :*}
end
