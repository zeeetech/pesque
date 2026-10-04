defmodule PesqueWeb.BlobTest do
  @moduledoc """
  The two blob endpoints over real requests: what uploadBlob answers, what
  getBlob serves, and the headers that decide what a browser does with bytes
  an attacker chose.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Blob
  alias Pesque.CID
  alias Pesque.Did
  alias PesqueWeb.Endpoint

  @password "hunter2hunter2"
  @upload "/xrpc/com.atproto.repo.uploadBlob"
  @download "/xrpc/com.atproto.sync.getBlob"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
    alice = create("alice")

    %{alice: alice, token: access(alice)}
  end

  test "uploadBlob answers the blob reference for the raw bytes", ctx do
    conn = upload(ctx.token, "hello", "image/jpeg")

    assert conn.status == 200
    assert %{"mimeType" => "image/jpeg", "size" => 5, "ref" => %{"$link" => cid}} = blob(conn)
    assert cid == CID.to_string(CID.from_data("hello", CID.raw()))
  end

  test "getBlob serves the bytes back under the stored mime type", ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])

    conn = get_blob(ctx.alice.did, cid)

    assert conn.status == 200
    assert conn.resp_body == "hello"

    expected = [
      {"content-type", "image/jpeg"},
      {"content-length", "5"},
      {"x-content-type-options", "nosniff"},
      {"content-disposition", "attachment; filename=\"" <> cid <> "\""},
      {"content-security-policy", "default-src 'none'; sandbox"}
    ]

    for {name, value} <- expected do
      assert get_resp_header(conn, name) == [value], name
    end
  end

  # The CSP the controller sets has to be the one that ships, not the global
  # one, or the sandbox on an attacker-supplied html blob is worth nothing.
  test "getBlob replaces the global content security policy", ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])

    conn = get_blob(ctx.alice.did, cid)

    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "sandbox"
    refute policy =~ "frame-ancestors"
  end

  test "getBlob resolves the did through a handle as well", ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])

    assert get_blob(ctx.alice.handle, cid).resp_body == "hello"
  end

  test "getBlob answers RepoNotFound, BlobNotFound and InvalidRequest as the lexicon names them",
       ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])

    unknown = get_blob(ghost_did(), cid)
    assert unknown.status == 400
    assert %{"error" => "RepoNotFound"} = JSON.decode!(unknown.resp_body)

    absent = get_blob(ctx.alice.did, CID.to_string(CID.from_data("never uploaded", CID.raw())))
    assert absent.status == 400
    assert %{"error" => "BlobNotFound"} = JSON.decode!(absent.resp_body)

    for malformed <- [
          "",
          "not a cid",
          "bafkrei",
          "../../etc/passwd",
          "bafyreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ] do
      conn = get_blob(ctx.alice.did, malformed)

      assert conn.status == 400, malformed
      assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
    end

    missing = request("#{@download}?did=#{enc(ctx.alice.did)}")
    assert missing.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(missing.resp_body)
  end

  # A blob CID is sha2-256 over raw bytes, so a record's own CID is never a
  # valid blob CID and must not be served out of the blocks table.
  test "getBlob will not serve a record cid", ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])
    record_cid = CID.to_string(CID.from_data("hello"))

    assert record_cid != cid

    conn = get_blob(ctx.alice.did, record_cid)
    assert conn.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
  end

  test "uploadBlob refuses an empty body and one over the limit", ctx do
    empty = upload(ctx.token, "", "image/jpeg")
    assert empty.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(empty.resp_body)

    oversize = upload(ctx.token, String.duplicate("a", 5 * 1024 * 1024 + 1), "image/jpeg")
    assert oversize.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(oversize.resp_body)
  end

  # A filesystem failure is the server's problem, not the client's. What matters
  # is that Blob.put/3 answers a reason the endpoint can map rather than passing
  # the raw posix reason through a with/else that never heard of it.
  test "a blob that cannot be written answers :unwritable", ctx do
    cid = CID.from_data("hello", CID.raw())
    dir = Path.dirname(Blob.path(ctx.alice.did, cid))

    # A file where the per-account directory belongs: mkdir_p cannot make it.
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "not a directory")

    on_exit(fn -> File.rm(dir) end)

    assert {:error, :unwritable} = Blob.put(ctx.alice.did, cid, "hello")
  end

  # Plug.Parsers claims these two before the router runs and leaves nothing to
  # read, so the controller refuses them by name instead of moving the parsers
  # out of the endpoint for one route.
  test "uploadBlob refuses the two media types the parsers already ate", ctx do
    for media_type <- ["application/json", "application/x-www-form-urlencoded"] do
      conn = upload(ctx.token, JSON.encode!(%{"hello" => "world"}), media_type)

      assert conn.status == 415, media_type
      assert %{"error" => "UnsupportedMediaType"} = JSON.decode!(conn.resp_body)
    end
  end

  test "uploadBlob refuses a content-length that disagrees with the body", ctx do
    conn = post_raw(ctx.token, "hello", "image/jpeg", "99")

    assert conn.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
    # helpers
    assert %{"message" => message} = JSON.decode!(conn.resp_body)
    assert message =~ "content-length"
  end

  test "uploadBlob stores under the authenticated did and nothing else", ctx do
    bob = create("bob")

    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])

    assert Blob.fetch(ctx.alice.did, CID.parse(cid)) == {:ok, "hello", "image/jpeg"}
    assert Blob.fetch(bob.did, CID.parse(cid)) == {:error, :not_found}
  end

  test "a row whose file is gone is served as a clean miss, not a crash", ctx do
    cid = ctx.token |> upload("hello", "image/jpeg") |> blob() |> get_in(["ref", "$link"])
    File.rm!(Blob.path(ctx.alice.did, CID.parse(cid)))

    conn = get_blob(ctx.alice.did, cid)
    assert conn.status == 400
    assert %{"error" => "BlobNotFound"} = JSON.decode!(conn.resp_body)
  end

  test "a record carrying an unparseable $link is a 400, not a crash", ctx do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(ctx.alice.did)

    conn = write_record(ctx.token, ctx.alice.handle, %{"$link" => "bafkrei"})

    assert conn.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
    assert Process.alive?(pid), "the record write must not take the RepoServer down"
  end

  test "a record carrying an unparseable $bytes value is a 400", ctx do
    conn = write_record(ctx.token, ctx.alice.handle, %{"$bytes" => "not base64!!"})

    assert conn.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
  end

  test "a record DAG-CBOR cannot encode is a 400, not a crash", ctx do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(ctx.alice.did)

    # JSON admits integers past uint64; the encoder raises on one, from inside
    # the commit. Invalid UTF-8 needs no guard here because the JSON encoder
    # refuses to emit it, so it never arrives over HTTP.
    conn = write_record(ctx.token, ctx.alice.handle, %{"text" => 18_446_744_073_709_551_616})

    assert conn.status == 400
    assert %{"error" => "InvalidRequest"} = JSON.decode!(conn.resp_body)
    assert Process.alive?(pid), "the record write must not take the RepoServer down"
  end

  defp write_record(token, repo, record) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> dispatch(
      Endpoint,
      :post,
      "/xrpc/com.atproto.repo.createRecord",
      JSON.encode!(%{repo: repo, collection: "app.bsky.feed.post", record: record})
    )
  end

  defp blob(conn), do: conn.resp_body |> JSON.decode!() |> Map.fetch!("blob")

  defp upload(token, body, media_type) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", media_type)
    |> dispatch(Endpoint, :post, @upload, body)
  end

  defp post_raw(token, body, media_type, content_length) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", media_type)
    |> put_req_header("content-length", content_length)
    |> dispatch(Endpoint, :post, @upload, body)
  end

  defp get_blob(did, cid) do
    request("#{@download}?did=#{enc(did)}&cid=#{enc(cid)}")
  end

  defp request(path) do
    dispatch(build_conn(), Endpoint, :get, path, nil)
  end

  defp create(name) do
    username = name <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    {:ok, user} =
      Accounts.create_account(username <> ".localhost", username <> "@localhost", @password)

    {:ok, _pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    user
  end

  defp access(user), do: Accounts.issue_session(user.did).access_jwt

  defp ghost_did, do: Did.did_for_username(:path_multi, Pesque.hostname(), unique("ghost"))

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  defp enc(value), do: URI.encode_www_form(value)
  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
