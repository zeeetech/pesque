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

  @doc "The scopes named in `scopes_supported`."
  def supported, do: @supported

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

      # openid is checked before the grantable set: it is a real scope that
      # simply does not go with atproto, and answering "this server does not
      # grant openid" would read as though openid were an unknown permission
      # rather than a profile this server refuses to mix in.
      "openid" in scopes ->
        {:error, :openid_not_supported}

      # Any other ungrantable scope is named before anything else is checked: a
      # client asking for a permission this server does not have should be told
      # which one, rather than being told it forgot atproto because the scope it
      # asked for was the one it spelled wrongly.
      not Enum.all?(scopes, &(&1 in @supported)) ->
        grantable(scopes)

      "atproto" not in scopes ->
        {:error, :missing_atproto_scope}

      true ->
        {:ok, Enum.join(scopes, " ")}
    end
  end

  def validate(_scope), do: {:error, :missing_scope}

  @doc "Whether every scope in a space-separated string is grantable."
  def grantable?(scope) when is_binary(scope) do
    scope
    |> String.split(" ", trim: true)
    |> Enum.all?(&(&1 in @supported))
  end

  def grantable?(_scope), do: false

  defp grantable(scopes) do
    case Enum.find(scopes, &(&1 not in @supported)) do
      nil -> {:ok, Enum.join(scopes, " ")}
      scope -> {:error, {:unsupported_scope, scope}}
    end
  end
end
