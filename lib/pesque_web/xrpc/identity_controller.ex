defmodule PesqueWeb.Xrpc.IdentityController do
  @moduledoc "DID documents and handle resolution."

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts
  alias PesqueWeb.Xrpc

  def did_document(conn, _params) do
    json(conn, Pesque.Identity.did_document())
  end

  def atproto_did(conn, _params) do
    if conn.host in served_names() do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, Pesque.Identity.did())
    else
      send_resp(conn, 404, "")
    end
  end

  def user_did_document(conn, %{"username" => username}) do
    case Accounts.did_document_for(username) do
      {:ok, doc} -> json(conn, doc)
      {:error, _reason} -> send_resp(conn, 404, "")
    end
  end

  def resolve_handle(conn, %{"handle" => handle}) do
    case Accounts.resolve_handle(handle) do
      {:ok, did} ->
        json(conn, %{"did" => did})

      {:error, _reason} ->
        Xrpc.error(conn, 400, "HandleNotFound", "no such handle on this server")
    end
  end

  def resolve_handle(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "missing required param: handle")
  end

  # The frame is the point of this endpoint: a handle change is only useful to
  # anyone whose identity cache is stale, and that cache is what the firehose
  # feeds. Accounts.update_handle/2 emits it once the row is written, so an
  # #identity frame never announces a handle this server does not resolve.
  def update_handle(conn, %{"handle" => handle}) do
    case Accounts.update_handle(conn.assigns.current_user, handle) do
      {:ok, _user} -> json(conn, %{})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_handle(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "missing required param: handle")
  end

  defp fail(conn, reason) do
    {status, name, message} = Xrpc.Errors.to_xrpc(reason)
    Xrpc.error(conn, status, name, message)
  end

  # The DID a client is told depends on the name it reached us under, so the
  # answer is only for the names this server actually serves.
  defp served_names do
    [Pesque.hostname(), Pesque.handle_domain()]
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&strip_port/1)
  end

  defp strip_port(host) do
    host |> String.split(":", parts: 2) |> hd() |> String.downcase()
  end
end
