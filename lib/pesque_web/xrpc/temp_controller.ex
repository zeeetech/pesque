defmodule PesqueWeb.Xrpc.TempController do
  @moduledoc """
  com.atproto.temp.checkHandleAvailability: the signup helper a client calls to
  learn whether a handle is free, and what to suggest when it is not.

  It is a read of public state, so it needs no token: account existence is
  already public through listRepos, and the answer here is the same fact.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts
  alias PesqueWeb.Xrpc

  @available "com.atproto.temp.checkHandleAvailability#resultAvailable"
  @unavailable "com.atproto.temp.checkHandleAvailability#resultUnavailable"

  def check_handle_availability(conn, %{"handle" => handle}) when is_binary(handle) do
    if Accounts.handle_available?(handle) do
      json(conn, %{"handle" => handle, "result" => %{"$type" => @available}})
    else
      suggestions = Accounts.handle_suggestions(handle, conn.params["email"])

      json(conn, %{
        "handle" => handle,
        "result" => %{"$type" => @unavailable, "suggestions" => suggestions}
      })
    end
  end

  def check_handle_availability(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "handle is required")
  end
end
