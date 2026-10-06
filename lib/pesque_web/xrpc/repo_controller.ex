defmodule PesqueWeb.Xrpc.RepoController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.Car
  alias Pesque.CBOR
  alias Pesque.CID
  alias Pesque.Commit
  alias Pesque.Keys
  alias Pesque.Lexicon
  alias Pesque.Repo
  alias Pesque.RepoServer
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

  def apply_writes(conn, params) do
    with {:ok, _did} <- with_owned_repo(conn, params),
         {:ok, writes} <- require_writes(params["writes"]) do
      {:ok, pid} = Pesque.RepoSupervisor.ensure_started(conn.assigns.did)

      validate = validate?(params)

      case Pesque.RepoServer.apply_writes(pid, writes,
             validate: validate,
             swap_commit: params["swapCommit"]
           ) do
        {:ok, result} ->
          json(conn, %{
            "commit" => result["commit"],
            "results" => results(result["changes"], validate)
          })

        {:error, reason} ->
          write_error(conn, reason)
      end
    else
      {:error, reason} -> write_error(conn, reason)
    end
  end

  # One result per write, in the order the client sent them, which is the order
  # the commit changed them in. A delete carries no uri or cid, so it answers
  # the empty object the lexicon declares rather than a null-filled one, and
  # validationStatus says what createRecord says: nobody checked the record
  # when validation was turned off, so nobody is claiming it is good.
  defp results(changes, validate) do
    status = if validate, do: "valid", else: "unknown"

    Enum.map(changes, fn
      %{"action" => "delete"} -> %{}
      change -> %{"uri" => change["uri"], "cid" => change["cid"], "validationStatus" => status}
    end)
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

  # The limit is the length given to read_body/2, so a body over it is refused
  # while the socket is still being drained rather than after the whole upload
  # has been held in memory and measured. A body of exactly the limit is the
  # largest accepted, so the read is capped at the limit itself and anything
  # past it arrives as {:more, _}. Nothing about the cap belongs to
  # Plug.Parsers: it claims only json and urlencoded, which blob_media_type/1
  # turns away before a byte is read, so the two media types a blob cannot
  # arrive as are the only ones the endpoint's length option ever sees.
  defp read_blob_body(conn) do
    case read_body(conn, length: Blob.max_bytes()) do
      {:ok, bytes, conn} ->
        {:ok, bytes, conn}

      {:more, _partial, _conn} ->
        {:error, blob_too_large()}

      {:error, reason} ->
        {:error, {400, "InvalidRequest", "could not read the request body: #{reason}"}}
    end
  end

  # 413 is what the XRPC conventions reserve for a body too large, and it is the
  # only status a client can tell apart from a malformed request by the status
  # alone: a caller that can shrink its upload retries, and a caller that
  # cannot fix its request does not. Blob.max_bytes/0 is the same value
  # describeServer advertises, so the message says the cap that was applied
  # rather than one the client has to guess.
  defp blob_too_large do
    {413, "PayloadTooLarge", "blob is larger than #{Blob.max_bytes()} bytes"}
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

  # import (behind PesqueWeb.Plugs.Auth)

  # A whole repo arrives in one request and lands in one transaction. The CAR
  # is decoded and walked before anything is written, so a malformed one is a
  # 400 and not a half-imported repo, and the body is capped like a blob's
  # before a byte of it is held. The lexicon names the Content-Length header as
  # required, so its absence is refused rather than treated as an unknown
  # length.
  #
  # The commit the CAR carried cannot keep its signature: this is a did:web
  # server and the key for the DID is the one this server holds, not the one
  # the exporting PDS signed with. So the import signs a new commit over the
  # imported tree with this server's key for the account, and that commit's
  # `prev` is the imported commit's CID, which continues the chain instead of
  # starting a second one.
  def import_repo(conn, _params) do
    with {:ok, declared} <- import_content_length(conn),
         {:ok, bytes} <- read_import_body(conn, declared),
         {:ok, imported} <- Car.decode_repo(bytes),
         :ok <- check_import_did(imported.commit, conn.assigns.did),
         {:ok, _did} <- persist_import(conn.assigns.did, imported) do
      json(conn, %{})
    else
      {:error, {status, name, message}} -> Xrpc.error(conn, status, name, message)
      {:error, reason} -> write_error(conn, reason)
    end
  end

  defp import_content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 ->
            {:ok, n}

          _other ->
            {:error, {400, "InvalidRequest", "content-length must be a non-negative integer"}}
        end

      [] ->
        {:error, {400, "InvalidRequest", "importRepo requires a content-length header"}}
    end
  end

  # The declared length is checked before the read so an over-large import is
  # refused on the header alone, and the read is capped so a length that lies
  # low is still bounded. Both turn into the same 413 the blob path answers,
  # which is the one status a client can tell from a malformed request.
  defp read_import_body(conn, declared) do
    if declared > Pesque.repo_import_max_bytes() do
      {:error, import_too_large()}
    else
      case read_body(conn, length: Pesque.repo_import_max_bytes()) do
        {:ok, bytes, _conn} ->
          {:ok, bytes}

        {:more, _partial, _conn} ->
          {:error, import_too_large()}

        {:error, reason} ->
          {:error, {400, "InvalidRequest", "could not read the request body: #{reason}"}}
      end
    end
  end

  defp import_too_large do
    {413, "PayloadTooLarge", "repo is larger than #{Pesque.repo_import_max_bytes()} bytes"}
  end

  # The commit in a CAR names the repo it was exported from, so importing one
  # into a different account is refused rather than stored under the wrong DID.
  defp check_import_did(%{"did" => did}, did), do: :ok
  defp check_import_did(_commit, _did), do: {:error, :invalid_car}

  # The new commit is built and signed before the store is touched, so a key
  # this server cannot load leaves the existing repo exactly as it was. The
  # process is stopped before the rows are replaced, because it caches the
  # entries and head those rows hold; it starts again, from the rows this
  # wrote, on the next request.
  defp persist_import(did, imported) do
    case Keys.ensure(did) do
      {:ok, key} ->
        state = %{
          did: did,
          clock_id: :rand.uniform(1024) - 1,
          priv: key.priv,
          entries: imported.entries,
          rev: nil,
          tid_int: 0,
          commit_cid: imported.commit_cid,
          root_cid: nil
        }

        {:ok, prepared} = Commit.commit(state, [])
        RepoServer.stop(did)
        write_import(did, imported, prepared)

      {:error, _reason} ->
        {:error, :key_unavailable}
    end
  end

  defp write_import(did, imported, prepared) do
    new_blocks =
      Map.new(prepared.all_blocks, fn {cid, bytes} -> {CID.to_string(cid), bytes} end)

    result =
      Repo.transaction(
        fn ->
          RepoStore.delete_records!(did)
          RepoStore.delete_blocks!(did)
          RepoStore.insert_blocks!(did, Map.merge(imported.blocks, new_blocks))

          Enum.each(imported.records, fn {key, {cid, data}} ->
            [collection, rkey] = String.split(key, "/", parts: 2)
            RepoStore.put_record!(did, collection, rkey, CID.to_string(cid), data)
          end)

          RepoStore.put_meta!("root:" <> did, CID.to_string(prepared.root_cid))
          RepoStore.put_meta!("rev:" <> did, prepared.rev)
          RepoStore.put_meta!("tid_int:" <> did, Integer.to_string(prepared.tid_int))
          RepoStore.put_meta!("commit:" <> did, CID.to_string(prepared.commit_cid))
          :ok
        end,
        mode: :immediate
      )

    case result do
      {:ok, :ok} -> {:ok, did}
      {:error, reason} -> {:error, reason}
    end
  end

  # authenticated reads

  # The blobs the account's records name but this server does not hold, which is
  # what a migration asks before it uploads the missing bytes. The record values
  # are walked for blob refs; a ref with no row behind it is the answer, and one
  # with a row is not. The cursor is an offset over the flattened list, matching
  # listRecords and listRepos so one paging shape is one thing to learn.
  def list_missing_blobs(conn, params) do
    did = conn.assigns.did
    limit = params |> Map.get("limit", "500") |> parse_int() |> max(1) |> min(1000)
    offset = params |> Map.get("cursor", "0") |> parse_int() |> max(0)

    missing = missing_blobs(did)
    more = offset + limit < length(missing)

    reply = %{"blobs" => Enum.slice(missing, offset, limit)}

    reply =
      if more,
        do: Map.put(reply, "cursor", Integer.to_string(offset + limit)),
        else: reply

    json(conn, reply)
  end

  defp missing_blobs(did) do
    did
    |> RepoStore.records_with_data()
    |> Enum.flat_map(&missing_in_record(did, &1))
    |> Enum.sort_by(&{&1["recordUri"], &1["cid"]})
  end

  defp missing_in_record(did, record) do
    uri = "at://#{did}/#{record.collection}/#{record.rkey}"

    record.data
    |> record_blob_cids()
    |> Enum.reject(&RepoStore.get_blob(did, &1))
    |> Enum.map(&%{"cid" => &1, "recordUri" => uri})
  end

  # A record's bytes decode to the shape the encoder wrote, so a blob ref is a
  # map carrying $type "blob" and a ref that is already a %CID{}. The walk
  # descends maps and lists and stops at anything else, because a blob ref can
  # sit under an array or a union like any other value.
  defp record_blob_cids(data) do
    data |> CBOR.decode!() |> blob_cids([])
  rescue
    _ -> []
  end

  defp blob_cids(%{"$type" => "blob", "ref" => %CID{} = cid}, acc),
    do: [CID.to_string(cid) | acc]

  defp blob_cids(%CBOR.Bytes{}, acc), do: acc
  defp blob_cids(%CID{}, acc), do: acc

  defp blob_cids(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> blob_cids(value, acc) end)

  defp blob_cids(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &blob_cids/2)

  defp blob_cids(_other, acc), do: acc

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

  defp require_writes(writes) when is_list(writes), do: {:ok, writes}
  defp require_writes(_writes), do: {:error, :missing_params}

  defp write_error(conn, :missing_params),
    do: Xrpc.error(conn, 400, "InvalidRequest", "missing required params")

  # One write of a batch failed and none of them landed, so the answer names
  # which one rather than reporting a bare reason a client would have to match
  # back to its own list. A malformed write is a request-level reason rather
  # than a domain one, so it is named here instead of being handed to
  # Errors.to_xrpc/1, which decides on domain reasons only.
  defp write_error(conn, {:write_failed, index, {:invalid_record, errors}}) do
    Xrpc.error(
      conn,
      400,
      "InvalidRequest",
      "write #{index} does not match its collection: #{describe(errors)}"
    )
  end

  defp write_error(conn, {:write_failed, index, :missing_params}) do
    Xrpc.error(
      conn,
      400,
      "InvalidRequest",
      "write #{index} is missing a required field"
    )
  end

  defp write_error(conn, {:write_failed, index, reason}) do
    {status, name, message} = Xrpc.Errors.to_xrpc(reason)
    Xrpc.error(conn, status, name, "write #{index}: #{message}")
  end

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
