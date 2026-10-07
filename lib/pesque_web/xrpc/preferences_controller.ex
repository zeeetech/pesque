defmodule PesqueWeb.Xrpc.PreferencesController do
  @moduledoc """
  app.bsky.actor.getPreferences and putPreferences.

  These are always local: the PDS owns the account's private preferences, and
  an `atproto-proxy` header on either method is ignored. The stored document is
  opaque, so an app's own `$type` entries round-trip untouched.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Preferences
  alias PesqueWeb.Xrpc

  def get_preferences(conn, _params) do
    case Preferences.get(conn.assigns.did) do
      {:ok, preferences} -> json(conn, %{"preferences" => preferences})
      {:error, reason} -> Xrpc.error(conn, reason)
    end
  end

  def put_preferences(conn, %{"preferences" => preferences}) when is_list(preferences) do
    case Preferences.put(conn.assigns.did, preferences) do
      {:ok, :stored} -> json(conn, %{})
      {:error, reason} -> Xrpc.error(conn, reason)
    end
  end

  def put_preferences(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "preferences must be an array")
  end
end
