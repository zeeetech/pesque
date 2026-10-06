defmodule PesqueWeb.Xrpc.IdentityController do
  @moduledoc "DID documents and handle resolution."

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Accounts
  alias Pesque.Plc
  alias PesqueWeb.Xrpc

  def did_document(conn, _params) do
    json(conn, Pesque.Identity.did_document())
  end

  # The HTTPS half of handle resolution. The DID answered depends on the name
  # the request arrived under, so the account is looked up by that handle and
  # its own stored DID is what comes back: a handle can be moved without its
  # DID moving, and answering with a re-derived one would resolve the handle to
  # an account that does not exist.
  #
  # Lookup is by the stored handle, so a name no row carries is a 404 rather
  # than a DID for somebody else's account.
  def atproto_did(conn, _params) do
    case did_for_host(conn.host) do
      {:ok, did} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, did)

      {:error, _reason} ->
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

  # What a client puts in the DID document it asks the old PDS to sign. The
  # account's own key and handle are answered from the row, not from the
  # request, so the recommendation always names this server.
  def get_recommended_did_credentials(conn, _params) do
    case Plc.recommended_credentials(conn.assigns.current_user) do
      {:ok, credentials} -> json(conn, credentials)
      {:error, reason} -> fail(conn, reason)
    end
  end

  # The operation is signed by the old PDS and arrives already signed; this
  # server's job is to refuse one that would leave the identity unusable from
  # here, then pass it on. A refusal happens before the directory sees it.
  def submit_plc_operation(conn, %{"operation" => operation}) do
    case Plc.submit_operation(conn.assigns.current_user, operation) do
      {:ok, _did} -> json(conn, %{})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def submit_plc_operation(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "missing required param: operation")
  end

  defp fail(conn, reason) do
    {status, name, message} = Xrpc.Errors.to_xrpc(reason)
    Xrpc.error(conn, status, name, message)
  end

  # The server's own names answer with the server's own DID, which is not the
  # same question as an account's handle: it is the host-level identity the
  # /.well-known/did.json beside this endpoint publishes.
  defp did_for_host(host) do
    if host in served_names() do
      {:ok, Pesque.Identity.did()}
    else
      Accounts.resolve_handle(host)
    end
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
