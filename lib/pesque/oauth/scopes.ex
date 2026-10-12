defmodule Pesque.OAuth.Scopes do
  @moduledoc """
  The scopes this server grants, and the only way to ask for one.

  `atproto` is not optional and is what tells a client the response is an
  atproto OAuth profile one. `transition:generic` is the app-password
  equivalent: records, blobs and preferences, but no account management, no
  email and no DMs. `transition:chat.bsky` adds the DMs back and depends on
  the generic grant; `transition:email` is the email address alone. Granular
  permission strings (`repo:...`, `rpc:...`, `blob:...`, `account:...`,
  `identity:...`) are accepted in their own right: what they grant is
  decided at request time by `Pesque.OAuth.Permission` and
  `Pesque.OAuth.Grants`.

  `include:` names a permission set, and the set is resolved here, at the
  door: an `include:` of a set this server can resolve (its own lexicons, or
  the configured aggregator) is accepted, and one it cannot is refused with
  the NSID named, because a token for a set nobody can read is a promise
  nothing can keep.

  A scope this server does not implement is an error, never a silent pass.
  Answering a token for a scope nothing enforces is how a client ends up
  believing it can do something the PDS will refuse later, with an error that
  names the wrong thing.
  """

  alias Pesque.OAuth.Permission
  alias Pesque.OAuth.PermissionSets

  @supported ~w(atproto transition:generic transition:chat.bsky transition:email)

  @doc "The scopes named in `scopes_supported`."
  def supported, do: @supported

  @doc """
  Validates a space-separated scope parameter.

  Answers {:ok, scopes} with the normalized space-separated string, or
  {:error, reason} naming the first scope that is not grantable, before
  anything else is checked. `atproto` has to be in there: a request without it
  is not an atproto OAuth request. A malformed scope string is refused as
  {:invalid_scope, scope}; an `include:` of a permission set that cannot be
  resolved is refused as {:unresolved_permission_set, nsid}.
  """
  def validate(nil), do: {:error, :missing_scope}

  def validate(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    cond do
      scopes == [] ->
        {:error, :missing_scope}

      # openid is checked before anything is parsed: it is a real scope that
      # simply does not go with atproto, and answering "this server does not
      # grant openid" would read as though openid were an unknown permission
      # rather than a profile this server refuses to mix in.
      "openid" in scopes ->
        {:error, :openid_not_supported}

      true ->
        case Enum.find_value(scopes, &refusal/1) do
          nil -> finish(scopes)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def validate(_scope), do: {:error, :missing_scope}

  # A scope is refused when it does not parse into a permission this server
  # understands, or when the set an include names cannot be resolved. The
  # offending scope is named before anything else is checked: a client asking
  # for a permission this server does not have should be told which one,
  # rather than being told it forgot atproto because the scope it asked for
  # was the one it spelled wrongly.
  defp refusal(scope) do
    case Permission.parse_scope(scope) do
      {:ok, %Permission{resource: :include, nsid: nsid}} ->
        case PermissionSets.resolve(nsid) do
          {:ok, _document} -> nil
          {:error, reason} -> {:error, reason}
        end

      {:ok, _permission} ->
        nil

      {:error, _reason} ->
        {:error, {:invalid_scope, scope}}
    end
  end

  defp finish(scopes) do
    cond do
      "atproto" not in scopes ->
        {:error, :missing_atproto_scope}

      # Granted-and-inert is the outcome the moduledoc refuses: the dependency
      # between the chat scope and the generic one is enforced at the door.
      "transition:chat.bsky" in scopes and "transition:generic" not in scopes ->
        {:error, :chat_requires_generic}

      true ->
        {:ok, Enum.join(scopes, " ")}
    end
  end
end
