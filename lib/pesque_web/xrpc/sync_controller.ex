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
            with {:ok, root} <- parse_cid(commit) do
              send_car(conn, root, RepoStore.blocks_map(did))
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

  # Blocks named by CID, for a consumer already walking a repo it fetched from
  # somewhere else: intermediate MST nodes, a record it holds a hash for, the
  # commit itself.
  #
  # The roots list is the commit CID alone, so the CAR names the state the
  # blocks belong to and a consumer can tell which repo version it is holding
  # without trusting the request. The commit's own bytes are not repeated: a
  # consumer that knows a CID already has the block, and asking for it again
  # is how a client says so.
  #
  # One CID this repo does not hold answers BlockNotFound for the whole
  # request rather than a CAR of the rest. A partial CAR is indistinguishable
  # from a repo that has nothing else, so a mirror would record a block as
  # absent when the truth is that it was not sent. The lexicon names the error
  # for exactly this case.
  def get_blocks(conn, %{"did" => did} = params) do
    with {:ok, cid_strings} <- requested_cids(conn, params),
         {:ok, did} <- served_repo(did) do
      serve_blocks(conn, did, cid_strings)
    else
      {:error, reason} -> sync_error(conn, reason)
    end
  end

  def get_blocks(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did and cids are required")
  end

  # One record, as the blocks that place it: the record block and the MST path
  # from the current root down to it. The path is what a mirror needs, since
  # the record block on its own says nothing about where in the repo it sits.
  def get_record(conn, %{"did" => did, "collection" => collection, "rkey" => rkey}) do
    case served_repo(did) do
      {:ok, did} -> serve_record(conn, did, collection, rkey)
      {:error, reason} -> sync_error(conn, reason)
    end
  end

  def get_record(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did, collection and rkey are required")
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

  # What a Relay or a crawling AppView asks before mirroring. The DID has
  # already been resolved by Accounts.repo_did/1, so the account exists here
  # and the only question left is whether it still has a repo behind it.
  def get_repo_status(conn, %{"did" => did}) do
    case Accounts.repo_did(did) do
      {:ok, did} ->
        json(conn, repo_status(did))

      {:error, _reason} ->
        Xrpc.error(conn, 404, "RepoNotFound", "unknown repo")
    end
  end

  def get_repo_status(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "did is required")
  end

  # active is not derived from the rev here: a repo with a rev that has been
  # deactivated is still a repo, and a relay asking has to be told it is not
  # being served. An account that never wrote keeps the same answer it had
  # before, which is a different fact with the same honest shape.
  defp repo_status(did) do
    with rev when is_binary(rev) <- RepoStore.get_meta("rev:" <> did),
         true <- Accounts.repo_active?(did) do
      %{"did" => did, "rev" => rev, "active" => true}
    else
      _ -> %{"did" => did, "active" => false, "status" => "deactivated"}
    end
  end

  # The whole-server enumeration. cursor is an offset the caller sends back
  # verbatim, matching listRecords, so one paging shape is one thing to learn.
  def list_repos(conn, params) do
    limit = params |> Map.get("limit", "500") |> parse_int() |> max(1) |> min(1000)
    offset = params |> Map.get("cursor", "0") |> parse_int() |> max(0)

    dids = Accounts.hosted_dids(limit + 1, offset)
    more = length(dids) > limit
    heads = RepoStore.all_repo_heads()
    deactivated = Accounts.deactivated_dids()

    repos =
      dids
      |> Enum.take(limit)
      |> Enum.map(&repo_entry(&1, heads, deactivated))

    reply = %{"repos" => repos}

    reply =
      if more,
        do: Map.put(reply, "cursor", Integer.to_string(offset + limit)),
        else: reply

    json(conn, reply)
  end

  defp repo_entry(did, heads, deactivated) do
    case {Map.get(heads, did), MapSet.member?(deactivated, did)} do
      {%{rev: rev, head: head}, false} when is_binary(rev) ->
        %{"did" => did, "head" => head, "rev" => rev, "active" => true}

      _ ->
        %{"did" => did, "head" => nil, "rev" => nil, "active" => false, "status" => "deactivated"}
    end
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

  # The CAR the lexicon names for every block endpoint, served exactly as
  # getRepo serves it: one content type, one body.
  defp send_car(conn, root, stored) do
    case parse_blocks(stored) do
      {:ok, blocks} ->
        conn
        |> put_resp_content_type("application/vnd.ipld.car")
        |> send_resp(200, Car.encode([root], blocks))

      :error ->
        Xrpc.error(conn, 500, "InternalServerError", "stored repo could not be decoded")
    end
  end

  # The commit is the root because it is the only block a consumer of any of
  # these endpoints is guaranteed to have: getRepo roots it the same way.
  defp commit_root(did) do
    case RepoStore.get_meta("commit:" <> did) do
      nil -> {:error, :no_commit}
      commit -> parse_cid(commit)
    end
  end

  defp serve_blocks(conn, did, cid_strings) do
    with {:ok, root} <- commit_root(did) do
      stored = RepoStore.blocks_by_cids(did, cid_strings)

      if map_size(stored) == length(cid_strings) do
        send_car(conn, root, stored)
      else
        sync_error(conn, :block_not_found)
      end
    else
      {:error, reason} -> sync_error(conn, reason)
      :error -> Xrpc.error(conn, 500, "InternalServerError", "stored repo could not be decoded")
    end
  end

  defp serve_record(conn, did, collection, rkey) do
    with {:ok, root} <- commit_root(did) do
      case RepoStore.get_record(did, collection, rkey) do
        nil ->
          sync_error(conn, :record_not_found)

        %{cid: cid} ->
          case RepoStore.blocks_for_path(did, cid) do
            {:ok, blocks} -> send_car(conn, root, blocks)
            {:error, reason} -> sync_error(conn, reason)
          end
      end
    else
      {:error, reason} -> sync_error(conn, reason)
      :error -> Xrpc.error(conn, 500, "InternalServerError", "stored repo could not be decoded")
    end
  end

  # A CID the tree cannot reach is not a client fault: the records table says
  # the record exists, so a walk that fails to find it means the stored blocks
  # disagree with each other.
  defp sync_error(conn, :record_not_found),
    do: Xrpc.error(conn, 400, "RecordNotFound", "no record at that key")

  defp sync_error(conn, :block_not_found),
    do: Xrpc.error(conn, 400, "BlockNotFound", "no stored block at one of the given CIDs")

  defp sync_error(conn, :no_root),
    do: Xrpc.error(conn, 500, "InternalServerError", "the stored tree does not reach that record")

  defp sync_error(conn, :no_commit),
    do: Xrpc.error(conn, 404, "RepoNotFound", "repo has no commits yet")

  defp sync_error(conn, :not_found), do: Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")

  defp sync_error(conn, :deactivated),
    do: Xrpc.error(conn, 400, "RepoDeactivated", "the repo is deactivated")

  defp sync_error(conn, :invalid_cids),
    do: Xrpc.error(conn, 400, "InvalidRequest", "cids must be an array of CID strings")

  defp sync_error(conn, :corrupt),
    do: Xrpc.error(conn, 500, "InternalServerError", "stored repo could not be walked")

  # A deactivated repo still resolves: getRepoStatus and checkAccountStatus have
  # to be able to say so. What it no longer does is serve blocks.
  defp served_repo(identifier) do
    case Accounts.repo_did(identifier) do
      {:ok, did} ->
        if Accounts.repo_active?(did), do: {:ok, did}, else: {:error, :deactivated}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # One cids parameter carries one CID, a repeated one carries an array, and
  # [] carries an array too. Which of those a client sends is not ours to
  # decide, so all three spellings are the same request.
  # The lexicon declares cids as an array, and the reference client writes an
  # array as repeated parameters rather than as cids[], so the parsed params
  # hold only the last one. The raw query string is the last place the whole
  # array is still there; the parsed shape covers a client that spelled it the
  # other way, or that sent one CID.
  defp requested_cids(conn, params) do
    repeated =
      conn.query_string
      |> String.split("&", trim: true)
      |> Enum.flat_map(fn
        "cids=" <> value -> [URI.decode_www_form(value)]
        _ -> []
      end)

    cond do
      repeated != [] -> validate_cids(repeated)
      is_list(params["cids"]) -> validate_cids(params["cids"])
      is_binary(params["cids"]) -> validate_cids([params["cids"]])
      true -> {:error, :invalid_cids}
    end
  end

  defp validate_cids(cids) do
    if cids != [] and Enum.all?(cids, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(cids)},
      else: {:error, :invalid_cids}
  end

  defp parse_blocks(stored) do
    Enum.reduce_while(stored, {:ok, %{}}, fn {cid, data}, {:ok, acc} ->
      case parse_cid(cid) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, parsed, data)}}
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

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
