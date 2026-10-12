defmodule Pesque.OAuth.Grants do
  @moduledoc """
  The permission grants a token carries, and the queries the auth plug asks
  of them.

  Grants are computed from the token's scope string, one grant per scope, and
  read leniently: a scope that no longer parses contributes nothing rather
  than failing the token, the same philosophy that lets a token issued before
  a scope was dropped keep verifying and keep answering requests.

  The three tiers that cut across the per-resource coverage question live
  here as queries of their own: the email field in getSession, the locally
  served preferences endpoints, and account management.
  """

  alias Pesque.OAuth.Permission

  @preferences %{
    get: "app.bsky.actor.getPreferences",
    put: "app.bsky.actor.putPreferences"
  }

  @doc """
  The grants a scope string carries.

  `atproto` means full account access only when it is the whole scope string,
  which is every token this server issued before granular scopes existed and
  every "Login with atproto" client. When anything else is granted, that
  other scope defines what the session may do and `atproto` is the profile
  marker the atproto OAuth profile requires in the string: without this, one
  always-present scope would silently widen every granular request back to
  full access, and nothing a user unchecks on the consent page could narrow
  anything.
  """
  @spec parse(binary() | nil) :: [Permission.t()]
  def parse(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    case scopes do
      ["atproto"] ->
        [%Permission{resource: :atproto}]

      _other ->
        for scope <- scopes,
            grant <- grant_of(scope),
            grant.resource != :atproto do
          grant
        end
    end
  end

  def parse(_scope), do: []

  defp grant_of(scope) do
    case Permission.parse_scope(scope) do
      # An include rides as its own grant and covers nothing directly
      # (Permission.covers?/2 says so); wherever expansion runs, it is
      # replaced by the concrete permissions the set stands for.
      {:ok, grant} -> [grant]
      {:error, _reason} -> []
    end
  end

  @doc "Whether any grant covers the required permission."
  @spec permits?([Permission.t()], Permission.t()) :: boolean()
  def permits?(grants, required), do: Enum.any?(grants, &Permission.covers?(&1, required))

  @doc """
  Whether the token holder may see the account email, which getSession
  includes only for a grant that names it.
  """
  @spec email_visible?([Permission.t()]) :: boolean()
  def email_visible?(grants) do
    Enum.any?(grants, fn
      %Permission{resource: :atproto} -> true
      %Permission{resource: :transition_email} -> true
      %Permission{resource: :account, attr: :email} -> true
      _other -> false
    end)
  end

  @doc """
  Whether the token may read or write the locally stored preferences.

  pesque serves these itself, where the ecosystem's permission sets model
  them as appview rpc calls, so a transitional grant or an rpc permission
  naming the method answers yes. The audience is ignored because the call
  never leaves this server.
  """
  @spec preferences?([Permission.t()], :get | :put) :: boolean()
  def preferences?(grants, verb) when verb in [:get, :put] do
    method = Map.fetch!(@preferences, verb)

    Enum.any?(grants, fn
      %Permission{resource: :atproto} -> true
      %Permission{resource: :transition_generic} -> true
      %Permission{resource: :rpc, lxm: lxms} -> method in lxms
      _other -> false
    end)
  end
end
