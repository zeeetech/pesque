defmodule PesqueWeb.Xrpc.SyncController do
  use Phoenix.Controller, formats: [:json]

  alias Pesque.{CID, Car, Identity, RepoStore}
  alias PesqueWeb.Xrpc

  def get_repo(conn, %{"did" => did}) do
    if did == Identity.did() do
      case RepoStore.get_meta("commit:" <> did) do
        nil ->
          Xrpc.error(conn, 404, "RepoNotFound", "repo has no commits yet")

        commit ->
          blocks = Map.new(RepoStore.blocks_for(did), fn b -> {CID.parse(b.cid), b.data} end)
          car = Car.encode([CID.parse(commit)], blocks)

          conn
          |> put_resp_content_type("application/vnd.ipld.car")
          |> send_resp(200, car)
      end
    else
      Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_repo(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end

  def get_latest_commit(conn, %{"did" => did}) do
    if did == Identity.did() do
      case {RepoStore.get_meta("commit:" <> did), RepoStore.get_meta("rev:" <> did)} do
        {cid, rev} when is_binary(cid) and is_binary(rev) ->
          json(conn, %{"cid" => cid, "rev" => rev})

        _ ->
          Xrpc.error(conn, 404, "RepoNotFound", "repo has no commits")
      end
    else
      Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_latest_commit(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end
end
