defmodule PesqueWeb.Xrpc.IdentityController do
  use Phoenix.Controller, formats: [:json]

  def did_document(conn, _params) do
    json(conn, Pesque.Identity.did_document())
  end

  def resolve_handle(conn, %{"handle" => handle}) do
    if String.downcase(handle) == Pesque.Identity.handle() do
      json(conn, %{"did" => Pesque.Identity.did()})
    else
      PesqueWeb.Xrpc.error(conn, 400, "HandleNotFound", "no such handle on this server")
    end
  end

  def resolve_handle(conn, _params) do
    PesqueWeb.Xrpc.error(conn, 400, "InvalidRequest", "missing required param: handle")
  end
end
