defmodule PesqueWeb.ImportAccountTest do
  @moduledoc """
  createAccount carrying a `did`.

  A DID on createAccount means an account being imported: it starts deactivated
  and empty, and the DID has to be one this server would serve for the handle,
  or its DID document would point somewhere this server cannot answer for.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.Did
  alias Pesque.RepoStore

  @account_path "/xrpc/com.atproto.server.createAccount"
  @password "hunter2hunter2"

  setup do
    put_registration(:open)
    :ok
  end

  test "a servable did:web creates a deactivated account with an empty repo" do
    username = unique("import")
    handle = username <> ".localhost"
    did = did_for(username)

    Registry.register(Pesque.EventRegistry, :firehose, [])

    conn = create(handle, did)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["did"] == did
    assert body["handle"] == handle
    refute body["active"]

    user = Accounts.get_user(did)
    assert user
    refute user.active

    refute RepoStore.get_meta("commit:" <> did)
    assert RepoStore.records_for(did) == []

    assert_receive {:firehose_frame, frame}
    {header, account} = decode(frame)

    assert header == %{"op" => 1, "t" => "#account"}
    assert account["did"] == did
    refute account["active"]
    assert account["status"] == "deactivated"
  end

  test "a did this server would not serve for the handle is refused" do
    username = unique("import")
    handle = username <> ".localhost"

    conn = create(handle, "did:web:elsewhere.example:user:" <> username)

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "UnsupportedDomain"
    assert Accounts.repo_did(handle) == {:error, :not_found}
  end

  test "a did whose handle is under another domain is refused" do
    username = unique("import")

    conn = create(username <> ".notlocalhost", did_for(username))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "HandleNotAvailable"
  end

  defp create(handle, did) do
    xrpc_post(
      @account_path,
      %{
        "handle" => handle,
        "email" => unique("mail") <> "@localhost",
        "password" => @password,
        "did" => did
      },
      nil
    )
  end

  defp did_for(username),
    do:
      Did.did_for_username(:path_multi, Did.did_host(Pesque.hostname(), Pesque.port()), username)

  defp put_registration(mode) do
    previous = Application.get_env(:pesque, :registration)

    on_exit(fn -> Application.put_env(:pesque, :registration, previous) end)

    Application.put_env(:pesque, :registration, mode)
    :ok
  end

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end
end
