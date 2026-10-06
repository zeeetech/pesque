defmodule PesqueWeb.ImportAccountTest do
  @moduledoc """
  createAccount carrying a `did`: importing an identity this server did not
  mint.

  The caller proves control of the DID with a service-auth token signed by the
  DID's current signing key, so the DID may be any identity, not only one this
  server would derive. The account starts deactivated and empty until the move
  is finished.

  The DID document is an injected fake, so nothing here reaches the network.
  """

  use PesqueWeb.ConnCase, async: false

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.RepoStore
  alias Pesque.Secp256k1

  @account_path "/xrpc/com.atproto.server.createAccount"
  @lxm "com.atproto.server.createAccount"
  @password "hunter2hunter2"

  setup do
    put_registration(:open)
    put_env(:did_resolver_directory, PesqueWeb.ImportAccountTest.Resolver)
    :ok
  end

  test "a proven did creates a deactivated account with an empty repo" do
    {did, pub, priv} = identity()
    put_env(:test_did_resolution, {:ok, document(did, pub)})

    Registry.register(Pesque.EventRegistry, :firehose, [])

    conn = import_account(did, service_auth_token(did, Pesque.Identity.did(), @lxm, priv))

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert body["did"] == did
    assert String.ends_with?(body["handle"], ".localhost")
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

  test "a missing service auth token is refused and creates nothing" do
    {did, _pub, _priv} = identity()

    conn = import_account(did, nil)

    assert conn.status == 401
    assert JSON.decode!(conn.resp_body)["error"] == "AuthenticationRequired"
    refute Accounts.get_user(did)
  end

  test "a token for another audience is refused and creates nothing" do
    {did, pub, priv} = identity()
    put_env(:test_did_resolution, {:ok, document(did, pub)})

    conn = import_account(did, service_auth_token(did, "did:web:elsewhere.example", @lxm, priv))

    assert conn.status == 401
    refute Accounts.get_user(did)
  end

  test "a token for another method is refused and creates nothing" do
    {did, pub, priv} = identity()
    put_env(:test_did_resolution, {:ok, document(did, pub)})

    token = service_auth_token(did, Pesque.Identity.did(), "com.atproto.server.otherMethod", priv)

    conn = import_account(did, token)

    assert conn.status == 401
    refute Accounts.get_user(did)
  end

  test "a token signed by another key is refused and creates nothing" do
    {did, _pub, _priv} = identity()
    {doc_pub, _doc_priv} = Secp256k1.generate_keypair()
    put_env(:test_did_resolution, {:ok, document(did, doc_pub)})

    {_signer_pub, signer_priv} = Secp256k1.generate_keypair()
    token = service_auth_token(did, Pesque.Identity.did(), @lxm, signer_priv)

    conn = import_account(did, token)

    assert conn.status == 401
    refute Accounts.get_user(did)
  end

  test "a did that does not resolve is refused and creates nothing" do
    {did, _pub, priv} = identity()
    put_env(:test_did_resolution, {:error, :not_found})

    conn = import_account(did, service_auth_token(did, Pesque.Identity.did(), @lxm, priv))

    assert conn.status == 400
    assert JSON.decode!(conn.resp_body)["error"] == "UnresolvableDid"
    refute Accounts.get_user(did)
  end

  defp import_account(did, token) do
    xrpc_post(
      @account_path,
      %{
        "handle" => unique("import") <> ".localhost",
        "email" => unique("mail") <> "@localhost",
        "password" => @password,
        "did" => did
      },
      token
    )
  end

  defp identity do
    did = "did:plc:" <> Pesque.Base32.encode(:crypto.strong_rand_bytes(15))
    {pub, priv} = Secp256k1.generate_keypair()
    {did, pub, priv}
  end

  defp document(did, pub) do
    %{
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => did <> "#atproto",
          "type" => "Multikey",
          "controller" => did,
          "publicKeyMultibase" => Secp256k1.public_key_multibase(pub)
        }
      ]
    }
  end

  defp service_auth_token(iss, aud, lxm, priv) do
    now = System.system_time(:second)
    claims = %{"iss" => iss, "aud" => aud, "iat" => now, "exp" => now + 60, "lxm" => lxm}

    input =
      encode(JSON.encode!(%{"typ" => "JWT", "alg" => "ES256K"})) <>
        "." <> encode(JSON.encode!(claims))

    input <> "." <> encode(Secp256k1.sign(priv, input))
  end

  defp encode(bin), do: Base.url_encode64(bin, padding: false)

  defp decode(frame) do
    {header, rest} = CBOR.decode(frame)
    {body, ""} = CBOR.decode(rest)
    {header, body}
  end

  defp put_registration(mode), do: put_env(:registration, mode)

  defp put_env(key, value) do
    previous = Application.get_env(:pesque, key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pesque, key, previous),
        else: Application.delete_env(:pesque, key)
    end)

    Application.put_env(:pesque, key, value)
    :ok
  end
end

defmodule PesqueWeb.ImportAccountTest.Resolver do
  @moduledoc """
  A DID resolver that reads its answer from configuration rather than the
  network. `Pesque.DidResolver` runs a resolution in a monitored process, so a
  fake that stored the answer in the caller's process dictionary would not see
  it; application env is visible across processes.
  """

  def resolve(_did), do: Application.get_env(:pesque, :test_did_resolution, {:error, :not_found})
end
