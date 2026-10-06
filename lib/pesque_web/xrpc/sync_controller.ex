defmodule PesqueWeb.Xrpc.SyncController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Pesque.Accounts
  alias Pesque.Blob
  alias Pesque.Car
  alias Pesque.CID
  alias Pesque.RepoStore
  alias PesqueWeb.Xrpc

  def get_repo(conn, %{"did" => did}) do
    case Accounts.repo_did(did) do
      {:ok, did} ->
        case RepoStore.get_meta("commit:" <> did) do
          nil ->
            Xrpc.error(conn, 404, "RepoNotFound", "repo has no commits yet")

          commit ->
            with {:ok, root} <- parse_cid(commit),
                 {:ok, blocks} <- parse_blocks(did) do
              car = Car.encode([root], blocks)

              conn
              |> put_resp_content_type("application/vnd.ipld.car")
              |> send_resp(200, car)
            else
              :error ->
                Xrpc.error(conn, 500, "InternalServerError", "stored repo could not be decoded")
            end
        end

      {:error, _reason} ->
        Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_repo(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end

  def get_latest_commit(conn, %{"did" => did}) do
    case Accounts.repo_did(did) do
      {:ok, did} ->
        case {RepoStore.get_meta("commit:" <> did), RepoStore.get_meta("rev:" <> did)} do
          {cid, rev} when is_binary(cid) and is_binary(rev) ->
            json(conn, %{"cid" => cid, "rev" => rev})

          _ ->
            Xrpc.error(conn, 404, "RepoNotFound", "repo has no commits")
        end

      {:error, _reason} ->
        Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_latest_commit(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end

  # getBlob is public by lexicon: a blob is bytes anyone may fetch, and the
  # CID that names it sits inside a record anyone may read. What it serves is
  # attacker-chosen though, so the response pins down what a browser may do
  # with it. content-disposition is the one that matters and is not in the
  # spec: attachment is what stops a text/html blob from rendering as a
  # document from this server's origin. put_resp_header replaces rather than
  # appends, so the policy here is the one that ships, not the global one
  # from SecurityHeaders.
  def get_blob(conn, %{"did" => did, "cid" => cid}) do
    case Accounts.repo_did(did) do
      {:ok, did} ->
        case Blob.parse_cid(cid) do
          {:ok, blob_cid} -> send_blob(conn, did, blob_cid)
          {:error, _reason} -> Xrpc.error(conn, 400, "InvalidRequest", "cid is not a blob CID")
        end

      {:error, _reason} ->
        Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_blob(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did and cid are required")
  end

  defp send_blob(conn, did, cid) do
    case Blob.fetch(did, cid) do
      {:ok, bytes, mime_type} ->
        conn
        |> put_resp_header("content-type", mime_type || "application/octet-stream")
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="#{CID.to_string(cid)}")
        )
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> send_resp(200, bytes)

      {:error, reason} ->
        {status, name, message} = Xrpc.Errors.to_xrpc(reason)
        Xrpc.error(conn, status, name, message)
    end
  end

  defp parse_blocks(did) do
    RepoStore.blocks_for(did)
    |> Enum.reduce_while({:ok, %{}}, fn b, {:ok, acc} ->
      case parse_cid(b.cid) do
        {:ok, cid} -> {:cont, {:ok, Map.put(acc, cid, b.data)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # The same store-level corruption decode_record/1 in RepoController answers
  # 500 for, so the two agree: a stored CID that does not parse is not a client
  # fault, and the string in the log is what ties the bad row back to storage.
  defp parse_cid(cid) do
    {:ok, CID.parse(cid)}
  rescue
    e ->
      Logger.error("parsing stored cid #{cid} failed: #{Exception.message(e)}")
      :error
  end
end
