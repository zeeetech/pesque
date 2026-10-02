defmodule PesqueWeb.Xrpc.RepoController do
  use Phoenix.Controller, formats: [:json]

  alias Pesque.{CBOR, Identity, Lexicon, RepoStore}
  alias PesqueWeb.Xrpc

  # writes (behind PesqueWeb.Plugs.Auth)

  def create_record(conn, params) do
    write(conn, params, :create)
  end

  def put_record(conn, params) do
    write(conn, params, :put)
  end

  def delete_record(conn, params) do
    with :ok <- require_self(conn, params["repo"]),
         :ok <- require_params(params, ["collection", "rkey"]) do
      {:ok, pid} = Pesque.RepoSupervisor.ensure_started(conn.assigns.did)

      case Pesque.RepoServer.delete_record(pid, params["collection"], params["rkey"]) do
        {:ok, result} ->
          json(conn, %{"commit" => result["commit"]})

        {:error, :record_not_found} ->
          Xrpc.error(conn, 400, "RecordNotFound", "no record at that key")

        {:error, :invalid_collection} ->
          Xrpc.error(conn, 400, "InvalidRequest", "collection is not a valid NSID")

        {:error, :invalid_rkey} ->
          Xrpc.error(conn, 400, "InvalidRecordKey", "rkey is not valid")
      end
    else
      {:error, reason} -> write_error(conn, reason)
    end
  end

  defp write(conn, params, action) do
    with :ok <- require_self(conn, params["repo"]),
         :ok <- require_params(params, ["collection"]),
         :ok <- require_record(params["record"]) do
      {:ok, pid} = Pesque.RepoSupervisor.ensure_started(conn.assigns.did)

      fun =
        if action == :create,
          do: &Pesque.RepoServer.create_record/4,
          else: &Pesque.RepoServer.put_record/4

      case fun.(pid, params["collection"], params["rkey"], params["record"]) do
        {:ok, result} ->
          [change] = result["changes"]

          json(conn, %{
            "uri" => change["uri"],
            "cid" => change["cid"],
            "commit" => result["commit"]
          })

        {:error, :record_exists} ->
          Xrpc.error(conn, 400, "InvalidRecordKey", "a record already exists at that key")

        {:error, :invalid_collection} ->
          Xrpc.error(conn, 400, "InvalidRequest", "collection is not a valid NSID")

        {:error, :invalid_rkey} ->
          Xrpc.error(conn, 400, "InvalidRecordKey", "rkey is not valid")
      end
    else
      {:error, reason} -> write_error(conn, reason)
    end
  end

  # reads (public)

  def get_record(conn, %{"repo" => repo, "collection" => collection, "rkey" => rkey}) do
    with {:ok, did} <- resolve_repo(repo) do
      case RepoStore.get_record(did, collection, rkey) do
        nil ->
          Xrpc.error(conn, 404, "RecordNotFound", "no record at that key")

        row ->
          json(conn, %{
            "uri" => "at://#{row.did}/#{row.collection}/#{row.rkey}",
            "cid" => row.cid,
            "value" => row.data |> CBOR.decode!() |> Lexicon.to_json()
          })
      end
    else
      :error -> Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def get_record(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo, collection, and rkey are required")
  end

  def list_records(conn, %{"repo" => repo, "collection" => collection} = params) do
    with {:ok, did} <- resolve_repo(repo) do
      limit = params |> Map.get("limit", "50") |> parse_int(50) |> max(1) |> min(100)
      offset = params |> Map.get("cursor", "0") |> parse_int(0) |> max(0)
      reverse = params["reverse"] == "true"

      rows = RepoStore.list_records(did, collection, limit + 1, offset, reverse)
      more = length(rows) > limit

      records =
        rows
        |> Enum.take(limit)
        |> Enum.map(fn row ->
          %{
            "uri" => "at://#{row.did}/#{row.collection}/#{row.rkey}",
            "cid" => row.cid,
            "value" => row.data |> CBOR.decode!() |> Lexicon.to_json()
          }
        end)

      reply = %{"records" => records}

      reply =
        if more, do: Map.put(reply, "cursor", Integer.to_string(offset + limit)), else: reply

      json(conn, reply)
    else
      :error -> Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def list_records(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo and collection are required")
  end

  def describe_repo(conn, %{"repo" => repo}) do
    with {:ok, did} <- resolve_repo(repo) do
      json(conn, %{
        "handle" => Identity.handle(),
        "did" => did,
        "didDoc" => Identity.did_document(),
        "collections" => RepoStore.collections_for(did),
        "handleIsCorrect" => true
      })
    else
      :error -> Xrpc.error(conn, 400, "RepoNotFound", "unknown repo")
    end
  end

  def describe_repo(conn, _params) do
    Xrpc.error(conn, 400, "InvalidRequest", "repo is required")
  end

  # helpers

  defp require_self(conn, repo) do
    if repo in [conn.assigns.did, Identity.handle()] do
      :ok
    else
      {:error, :wrong_repo}
    end
  end

  defp resolve_repo(repo) do
    if repo in [Identity.did(), Identity.handle()], do: {:ok, Identity.did()}, else: :error
  end

  defp require_params(params, keys) do
    if Enum.all?(keys, &is_binary(params[&1])), do: :ok, else: {:error, :missing_params}
  end

  defp require_record(record) when is_map(record), do: :ok
  defp require_record(_), do: {:error, :missing_params}

  defp write_error(conn, :wrong_repo),
    do: Xrpc.error(conn, 400, "InvalidRequest", "repo must be the authenticated account")

  defp write_error(conn, :missing_params),
    do: Xrpc.error(conn, 400, "InvalidRequest", "missing required params")

  defp parse_int(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp parse_int(_value, default), do: default
end
