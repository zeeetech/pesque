defmodule Pesque.OAuth.Scopes do
  @moduledoc """
  The scopes this server grants, and the only way to ask for one.

  `atproto` is not optional and is what tells a client the response is an
  atproto OAuth profile one. `transition:generic` is the app-password
  equivalent: records, blobs and preferences, but no account management and no
  DMs. chat.bsky is not implemented here, so `transition:chat.bsky` is
  refused rather than granted and then ignored.

  A scope this server does not implement is an error, never a silent pass.
  Answering a token for a scope nothing enforces is how a client ends up
  believing it can do something the PDS will refuse later, with an error that
  names the wrong thing.
  """

  @supported ~w(atproto transition:generic)

  # What each scope reaches, and the one place that answer is written down.
  #
  # `atproto` is the whole account: reading and writing its records and blobs,
  # and the endpoints that manage the account itself. `transition:generic` is
  # the app-password equivalent, so it stops short of the second.
  #
  # The permissions are what the router asks about, not the scopes: a route
  # says what it needs to reach and the granted scopes are checked against it,
  # so adding an endpoint never means writing a scope check and never means
  # guessing which of the two scopes it belongs behind.
  @permissions %{
    "atproto" => [:read, :write, :account],
    "transition:generic" => [:read, :write]
  }

  @all_permissions [:read, :write, :account]

  @doc "The scopes named in `scopes_supported`."
  def supported, do: @supported

  @doc """
  Every permission a token with this scope string was granted, as a list.

  A token is granted the narrowest scope it asked for, not the union of them:
  `atproto` is in every token, so a union would make `transition:generic`
  decorative and an app password would be handed the account management it was
  asked not to have. Intersecting means asking for the compatibility scope
  costs exactly what it is meant to.

  A scope this server does not grant contributes nothing rather than raising,
  because a token handed out before a scope was dropped still verifies and
  still has to answer requests: it just answers fewer of them. A token with
  no scope at all is granted nothing, which is the same answer as one asking
  for everything this server has never heard of.
  """
  def permissions(scope) when is_binary(scope) do
    case String.split(scope, " ", trim: true) do
      [] -> []
      granted -> narrow(granted, @all_permissions)
    end
  end

  def permissions(_scope), do: []

  defp narrow([name | rest], granted) do
    case Map.get(@permissions, name) do
      nil -> narrow(rest, [])
      allowed -> narrow(rest, Enum.filter(granted, &(&1 in allowed)))
    end
  end

  defp narrow([], granted), do: granted

  @doc "Whether a granted scope string carries a permission."
  def permit?(scope, permission) when is_binary(scope),
    do: permission in permissions(scope)

  def permit?(_scope, _permission), do: false

  @doc """
  Validates a space-separated scope parameter.

  Answers {:ok, scopes} with the normalized space-separated string, or
  {:error, reason} naming the first scope that is not grantable. `atproto` has
  to be in there: a request without it is not an atproto OAuth request.
  """
  def validate(nil), do: {:error, :missing_scope}

  def validate(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    cond do
      scopes == [] ->
        {:error, :missing_scope}

      # openid is checked before the supported set: it is a real scope that
      # simply does not go with atproto, and answering "this server does not
      # grant openid" would read as though openid were an unknown permission
      # rather than a profile this server refuses to mix in.
      "openid" in scopes ->
        {:error, :openid_not_supported}

      # Any other ungrantable scope is named before anything else is checked: a
      # client asking for a permission this server does not have should be told
      # which one, rather than being told it forgot atproto because the scope it
      # asked for was the one it spelled wrongly.
      unsupported = Enum.find(scopes, &(&1 not in @supported)) ->
        {:error, {:unsupported_scope, unsupported}}

      "atproto" not in scopes ->
        {:error, :missing_atproto_scope}

      true ->
        {:ok, Enum.join(scopes, " ")}
    end
  end

  def validate(_scope), do: {:error, :missing_scope}
end
