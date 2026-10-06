defmodule PesqueWeb.Xrpc.RepoController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.CBOR
  alias Pesque.Lexicon
  alias Pesque.RepoStore
  alias PesqueWeb.Xrpc

  # Claimed by Plug.Parsers before the router runs, so the body is already
  # gone by the time a controller could read it.
  @parsed_media_types ["application/json", "application/x-www-form-urlencoded"]

  # writes (behind PesqueWeb.Plugs.Auth)

  def create_record(conn, params) do
    write(conn, params, :create)
  end

  def put_record(conn, params) do
    write(conn, params, :put)
  end

  def delete_record(conn, params) do
    with {:ok, _did} <- with_owned_repo(conn, params),
         :ok <- require_params(params, ["collection", "rkey"]) do
      {:ok, pid} = Pesque.RepoSupervisor.ensure_started(conn.assigns.did)

      case Pesque.RepoServer.delete_record(pid, params["collection"], params["rkey"]) do
        {:ok, result} ->
          json(conn, %{"commit" => result["commit"]})

        {:error, reason} ->
          write_error(conn, reason)
      end
    else
      {:error, reason} -> write_error(conn, reason)
    end
  end

  defp write(conn, params, action) do
    with {:ok, _did} <- with_owned_repo(conn, params),
         :ok <- require_params(params, ["collection"]),
         :ok <- require_record(params["record"]) do
      {:ok, pid} = Pesque.RepoSupervisor.ensure_started(conn.assigns.did)

      fun =
        if action == :create,
          do: &Pesque.RepoServer.create_record/5,
          else: &Pesque.RepoServer.put_record/5

      validate = validate?(params)

      case fun.(pid, params["collection"], params["rkey"], params["record"], validate: validate) do
        {:ok, result} ->
          [change] = result["changes"]

          json(conn, %{
            "uri" => change["uri"],
            "cid" => change["cid"],
            "commit" => result["commit"],
            "validationStatus" => if(validate, do: "valid", else: "unknown")
          })

        {:error, {:invalid_record, errors}} ->
          Xrpc.error(
            conn,
            400,
            "InvalidRequest",
            "record does not match #{params["collection"]}: #{describe(errors)}"
          )

        {:error, reason} ->
          write_error(conn, reason)
      end
    else
      {:error, reason} -> write_error(conn, reason)
    end
  end

  # validate is absent on almost every request and means true, so the default
  # is the one that reads as an omission. It arrives as a string from a form
  # body and as a boolean from JSON, and only "false" turns it off.
  defp validate?(params) do
    params["validate"] not in [false, "false"]
  end

  # The validator answers with a path per mistake, and a client that sent one
  # cannot act on "invalid record". Naming the fields is the difference between
  # a 400 the caller can fix and one it has to guess at.
  defp describe(errors) do
    errors
    |> Enum.map(fn {path, reason} ->
      "#{Enum.join(path, ".")} (#{reason_name(reason)})"
    end)
    |> Enum.join(", ")
  end

  # Reasons are atoms except for the format failures, which carry the parser
  # that stopped first so a server log can keep the specific one. A caller gets
  # the name, not the internals.
  defp reason_name(reason) when is_atom(reason), do: reason
  defp reason_name(reason) when is_tuple(reason), do: elem(reason, 0)

  # uploadBlob declares no repo parameter, so the request names no target: the
  # token decided it and the body cannot move it. authorize_write/2 is
  # deliberately not called here, because with conn.assigns.did on both sides
  # it compares a value with itself and would keep reading as a check long
  # after it stopped being one.
  def upload_blob(conn, _params) do
    with {:ok, media_type} <- blob_media_type(conn),
         {:ok, bytes, conn} <- read_blob_body(conn),
         :ok <- content_length_matches(conn, bytes),
         {:ok, blob} <- Blob.upload(conn.assigns.did, bytes, media_type) do
      json(conn, %{
        "blob" => %{
          "$type" => "blob",
          "ref" => %{"$link" => blob.cid},
          "mimeType" => blob.mime_type,
          "size" => blob.size
        }
      })
    else
      {:error, {status, name, message}} ->
        Xrpc.error(conn, status, name, message)

      {:error, reason} ->
        write_error(conn, reason)
    end
  end

  defp blob_media_type(conn) do
    media_type =
      conn
      |> get_req_header("content-type")
      |> List.first("application/octet-stream")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type in @parsed_media_types do
      {:error, {415, "UnsupportedMediaType", "uploadBlob takes the blob as the request body"}}
    else
      {:ok, media_type}
    end
  end

  defp read_blob_body(conn) do
    case read_body(conn, length: Blob.max_bytes() + 1) do
      {:ok, bytes, conn} ->
        {:ok, bytes, conn}

      {:more, _partial, _conn} ->
        {:error, {400, "InvalidRequest", "blob is larger than #{Blob.max_bytes()} bytes"}}

      {:error, reason} ->
        {:error, {400, "InvalidRequest", "could not read the request body: #{reason}"}}
    end
  end

  # A Content-Length is a claim about the body, not a fact about it, until the
  # body has actually been read.
  defp content_length_matches(conn, bytes) do
    size = Integer.to_string(byte_size(bytes))

    case get_req_header(conn, "content-length") do
      [^size | _] -> :ok
      [] -> :ok
      _ -> {:error, {400, "InvalidRequest", "content-length does not match the body"}}
    end
  end

  # reads (public)

  def get_record(conn, %{"repo" => repo, "collection" => collection, "rkey" => rkey} = params) do
    case resolve_repo(repo) do
      {:ok, did} ->
        case fetch_record(did, collection, rkey, params["cid"]) do
          nil ->
            Xrpc.error(conn, 404, "RecordNotFound", "no record at that key")

          {cid, data} ->
            case decode_record(cid, data) do
              {:ok, value} ->
                json(conn, %{
                  "uri" => "at://#{did}/#{collection}/#{rkey}",
                  "cid" => cid,
                  "value" => value
                })

              :error ->
                Xrpc.error(conn, 500, "InternalServerError", "stored record could not be decoded")
            end
        end

      {:error, _reason} ->
        Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_record(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo, collection, and rkey are required")
  end

  # A cid names one version of the record rather than the latest one. The
  # records table holds only the latest version, so an older one is answered
  # from the blocks table, for as long as the block sweeper has not yet
  # collected it.
  #
  # The uri answered is the key the caller asked about. Which key a superseded
  # version was written to is not recorded anywhere, so it cannot be checked
  # and is not claimed: a cid naming a block this repo stores is served under
  # the requested uri, and the caller is the one who knows both.
  defp fetch_record(did, collection, rkey, nil) do
    case RepoStore.get_record(did, collection, rkey) do
      nil -> nil
      row -> {row.cid, row.data}
    end
  end

  defp fetch_record(did, _collection, _rkey, cid) when is_binary(cid) do
    case RepoStore.get_block(did, cid) do
      nil -> nil
      block -> {block.cid, block.data}
    end
  end

  defp fetch_record(did, collection, rkey, _cid) do
    fetch_record(did, collection, rkey, nil)
  end

  # A limit or cursor that is not a whole number reads as 0, and the clamps
  # below turn that into the smallest page and the first page respectively.
  # That is a deliberate choice over a 400: a paging parameter a client got
  # wrong should not fail a read that would otherwise succeed.
  def list_records(conn, %{"repo" => repo, "collection" => collection} = params) do
    case resolve_repo(repo) do
      {:ok, did} ->
        limit = params |> Map.get("limit", "50") |> parse_int() |> max(1) |> min(100)
        offset = params |> Map.get("cursor", "0") |> parse_int() |> max(0)
        reverse = params["reverse"] == "true"

        rows = RepoStore.list_records(did, collection, limit + 1, offset, reverse)
        more = length(rows) > limit

        records =
          rows
          |> Enum.take(limit)
          |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
            case decode_record(row.cid, row.data) do
              {:ok, value} ->
                {:cont,
                 {:ok,
                  [
                    %{
                      "uri" => "at://#{row.did}/#{row.collection}/#{row.rkey}",
                      "cid" => row.cid,
                      "value" => value
                    }
                    | acc
                  ]}}

              :error ->
                {:halt, :error}
            end
          end)

        case records do
          {:ok, records} ->
            reply = %{"records" => Enum.reverse(records)}

            reply =
              if more,
                do: Map.put(reply, "cursor", Integer.to_string(offset + limit)),
                else: reply

            json(conn, reply)

          :error ->
            Xrpc.error(conn, 500, "InternalServerError", "stored record could not be decoded")
        end

      {:error, _reason} ->
        Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def list_records(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo and collection are required")
  end

  def describe_repo(conn, %{"repo" => repo}) do
    with {:ok, did} <- resolve_repo(repo),
         %User{} = user <- Accounts.get_user(did),
         {:ok, did_doc} <- Accounts.did_document_for(user) do
      json(conn, %{
        "handle" => user.handle,
        "did" => user.did,
        "didDoc" => did_doc,
        "collections" => RepoStore.collections_for(did),
        "handleIsCorrect" => handle_is_correct(user, did_doc)
      })
    else
      _ -> Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def describe_repo(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo is required")
  end

  # helpers

  # Local-only, and deliberately not the real thing. Confirming a handle means
  # resolving it from the network and checking who controls the domain, which
  # is out of scope here; what is checkable is that the document this server
  # publishes for the account claims the account's handle, and that the local
  # resolver maps that handle back to the same DID. Both halves are computed,
  # so a mismatch is reported as false rather than papered over with true.
  defp handle_is_correct(user, did_doc) do
    did_doc["alsoKnownAs"] == ["at://" <> user.handle] and
      Accounts.repo_did(user.handle) == {:ok, user.did}
  end

  # The token decides the target, this decides whether, and the request body
  # never supplies the target. The success value is conn.assigns.did and not
  # the resolved param on purpose: passing params["repo"] down instead would
  # read as the same check and write to whoever the body named.
  defp with_owned_repo(conn, params) do
    case Accounts.authorize_write(conn.assigns.current_user, params["repo"]) do
      :ok -> {:ok, conn.assigns.did}
      {:error, reason} -> {:error, reason}
    end
  end

  # A row whose bytes do not decode as DAG-CBOR is a store-level corruption,
  # not a client fault, so it answers 500. The CID in the log is what ties the
  # bad bytes back to the block in storage.
  defp decode_record(cid, data) do
    {:ok, data |> CBOR.decode!() |> Lexicon.to_json()}
  rescue
    e ->
      Logger.error("decoding record #{cid} failed: #{Exception.message(e)}")
      :error
  end

  defp resolve_repo(repo), do: Accounts.repo_did(repo)

  defp require_params(params, keys) do
    if Enum.all?(keys, &is_binary(params[&1])), do: :ok, else: {:error, :missing_params}
  end

  defp require_record(record) when is_map(record), do: :ok
  defp require_record(_), do: {:error, :missing_params}

  defp write_error(conn, :missing_params),
    do: Xrpc.error(conn, 400, "InvalidRequest", "missing required params")

  defp write_error(conn, reason) do
    {status, name, message} = Xrpc.Errors.to_xrpc(reason)
    Xrpc.error(conn, status, name, message)
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
