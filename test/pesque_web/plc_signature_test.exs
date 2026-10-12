defmodule PesqueWeb.PlcSignatureTest do
  @moduledoc """
  The two endpoints that sign a hosted did:plc account's move out:
  `requestPlcOperationSignature` issues the code and `signPlcOperation`
  spends it on a signed operation.

  There is no mail here, so the code reaches the operator through the log and
  the CLI (`pesque account plc-token`); the token lifecycle is pinned the way
  the deletion token's is, against the rows. The directory is an injected
  fake, though signing never calls it: the signature is the product.
  """

  use PesqueWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias Pesque.Accounts
  alias Pesque.CBOR
  alias Pesque.Cli
  alias Pesque.Did
  alias Pesque.Keys
  alias Pesque.Plc
  alias Pesque.Plc.Keys, as: PlcKeys
  alias Pesque.Plc.Operation
  alias Pesque.Accounts.Token
  alias Pesque.Repo
  alias Pesque.Secp256k1

  @request_path "/xrpc/com.atproto.identity.requestPlcOperationSignature"
  @sign_path "/xrpc/com.atproto.identity.signPlcOperation"

  setup do
    put_identity(:plc)
    put_env(:plc_client, Pesque.Plc.TestClient)
    :ok
  end

  describe "requestPlcOperationSignature" do
    test "the code is not answered in the body, only hashed in the row" do
      user = create_account("alice")

      conn = xrpc_post(@request_path, %{}, token(user))

      assert conn.status == 200
      assert json_body(conn) == %{}

      assert %Token{token_hash: hash, did: did, used_at: nil, purpose: :plc_operation} =
               Repo.one!(from t in Token, where: t.did == ^user.did)

      assert did == user.did
      assert String.length(hash) == 64
    end

    # The operator's path, end to end: the code is asked over HTTP and read
    # out of the log, then spent at signPlcOperation. The suite logs at
    # :warning by configuration, so the level is raised here for the capture
    # and restored whatever the assertions inside answer.
    test "the code reaches the log, and the logged code signs" do
      user = create_account("alice")
      Logger.configure(level: :info)

      output =
        try do
          capture_log([metadata: [:token]], fn ->
            conn = xrpc_post(@request_path, %{}, token(user))
            assert conn.status == 200
          end)
        after
          Logger.configure(level: :warning)
        end

      assert output =~ "plc operation token issued"
      assert [code] = Regex.run(~r/token=(\S+)/, output, capture: :all_but_first)

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))

      assert conn.status == 200
    end

    test "it needs an access token" do
      conn = xrpc_post(@request_path, %{}, nil)

      assert conn.status == 401
    end
  end

  describe "signPlcOperation" do
    test "a signed operation with every field replaced comes back" do
      user = create_account("alice")
      code = request_token(user)

      operation =
        %{
          "token" => code,
          "rotationKeys" => ["did:key:zQ3shNewRotation"],
          "alsoKnownAs" => ["at://" <> user.handle],
          "verificationMethods" => %{"atproto" => account_key_did(user)},
          "services" => %{
            "atproto_pds" => %{
              "type" => "AtprotoPersonalDataServer",
              "endpoint" => "https://elsewhere.example"
            }
          }
        }

      conn = xrpc_post(@sign_path, operation, token(user))

      assert conn.status == 200
      assert %{"operation" => signed} = json_body(conn)

      genesis = stored_operation(user)
      assert signed["prev"] == Operation.cid(genesis)
      assert signed["type"] == "plc_operation"
      assert signed["rotationKeys"] == ["did:key:zQ3shNewRotation"]
      assert signed["alsoKnownAs"] == ["at://" <> user.handle]
      assert signed["verificationMethods"] == %{"atproto" => account_key_did(user)}

      assert signed["services"] == %{
               "atproto_pds" => %{
                 "type" => "AtprotoPersonalDataServer",
                 "endpoint" => "https://elsewhere.example"
               }
             }

      assert signed["sig"]
    end

    test "fields left out carry the stored operation's forward" do
      user = create_account("alice")
      genesis = stored_operation(user)

      conn = xrpc_post(@sign_path, %{"token" => request_token(user)}, token(user))

      assert %{"operation" => signed} = json_body(conn)

      assert signed["rotationKeys"] == genesis["rotationKeys"]
      assert signed["alsoKnownAs"] == genesis["alsoKnownAs"]
      assert signed["verificationMethods"] == genesis["verificationMethods"]
      assert signed["services"] == genesis["services"]
      assert signed["prev"] == Operation.cid(genesis)
    end

    test "an explicit null is an absent field" do
      user = create_account("alice")
      genesis = stored_operation(user)

      conn =
        xrpc_post(
          @sign_path,
          %{"token" => request_token(user), "rotationKeys" => nil},
          token(user)
        )

      assert %{"operation" => signed} = json_body(conn)
      assert signed["rotationKeys"] == genesis["rotationKeys"]
    end

    test "the signature verifies against the account's rotation key" do
      user = create_account("alice")

      conn = xrpc_post(@sign_path, %{"token" => request_token(user)}, token(user))

      assert %{"operation" => signed} = json_body(conn)

      {:ok, rotation_priv} = PlcKeys.load_rotation(user.did)
      pub = Secp256k1.public_from_private(rotation_priv)
      {:ok, sig} = Base.url_decode64(signed["sig"], padding: false)

      assert :crypto.verify(
               :ecdsa,
               :sha256,
               CBOR.encode(Map.delete(signed, "sig")),
               Secp256k1.raw_to_der(sig),
               [pub, :secp256k1]
             )
    end

    test "the output is exactly the operation, the shape the lexicon names" do
      user = create_account("alice")

      body =
        @sign_path
        |> xrpc_post(%{"token" => request_token(user)}, token(user))
        |> json_body()

      assert Map.keys(body) == ["operation"]
    end

    test "an empty request is an error, not a re-signature" do
      user = create_account("alice")

      conn = xrpc_post(@sign_path, %{}, token(user))

      assert conn.status == 400
      assert error_name(conn) == "InvalidRequest"
      assert conn.resp_body =~ "token"
      assert spent_tokens(user) == []
    end

    # The old PDS a move leaves is a pesque, and `pesque migrate` posts this
    # endpoint an empty body with a json content type. The parser reads that
    # as an empty request, so the answer is the same one.
    test "an empty body posts like an empty request" do
      user = create_account("alice")

      conn =
        build_conn()
        |> put_req_header("x-request-id", "0123456789abcdef0123456789abcdef")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token(user))
        |> dispatch(Endpoint, :post, @sign_path, "")

      assert conn.status == 400
      assert error_name(conn) == "InvalidRequest"
    end

    test "a field of the wrong shape is refused and the token survives" do
      user = create_account("alice")
      code = request_token(user)

      conn = xrpc_post(@sign_path, %{"token" => code, "rotationKeys" => "nope"}, token(user))

      assert conn.status == 400
      assert error_name(conn) == "InvalidRequest"
      assert spent_tokens(user) == []

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))

      assert conn.status == 200
    end

    test "the token is spent, and a second use is refused" do
      user = create_account("alice")
      code = request_token(user)

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))
      assert conn.status == 200
      assert length(spent_tokens(user)) == 1

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))

      assert conn.status == 401
      assert error_name(conn) == "InvalidToken"
    end

    test "an expired token answers ExpiredToken" do
      user = create_account("alice")
      code = request_token(user)

      {1, _} =
        Repo.update_all(
          from(t in Token, where: t.did == ^user.did and t.purpose == :plc_operation),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
        )

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))

      assert conn.status == 401
      assert error_name(conn) == "ExpiredToken"
    end

    test "a code minted for another account is refused" do
      alice = create_account("alice")
      bob = create_account("bob")
      alice_code = request_token(alice)

      conn = xrpc_post(@sign_path, %{"token" => alice_code}, token(bob))

      assert conn.status == 401
      assert error_name(conn) == "InvalidToken"
    end

    test "it needs an access token" do
      conn = xrpc_post(@sign_path, %{"token" => "whatever"}, nil)

      assert conn.status == 401
    end
  end

  describe "a did:web account" do
    setup do
      put_identity(:web)
      user = create_account("webuser")
      %{user: user}
    end

    test "requesting a code is refused", %{user: user} do
      conn = xrpc_post(@request_path, %{}, token(user))

      assert conn.status == 400
      assert error_name(conn) == "InvalidRequest"
    end

    test "signing is refused", %{user: user} do
      conn = xrpc_post(@sign_path, %{"token" => "whatever"}, token(user))

      assert conn.status == 400
      assert error_name(conn) == "InvalidRequest"
    end
  end

  describe "pesque account plc-token" do
    test "the verb mints a code signPlcOperation spends" do
      user = create_account("alice")

      output =
        capture_io(fn ->
          assert :ok = Cli.run(["account", "plc-token", "--did", user.did])
        end)

      assert output =~ "plc operation token for #{user.did}: "
      assert output =~ "single use"
      assert [code] = Regex.run(~r/token for #{user.did}: (\S+)/, output, capture: :all_but_first)

      conn = xrpc_post(@sign_path, %{"token" => code}, token(user))

      assert conn.status == 200
    end

    test "a did:web account is named as the reason" do
      put_identity(:web)
      user = create_account("webuser")

      assert {:error, :not_a_plc_account} =
               Cli.run(["account", "plc-token", "--handle", user.handle])
    end
  end

  # The domain function's answer, the one the controller swallows and the log
  # and the CLI carry to the operator.
  defp request_token(user) do
    {:ok, %{token: token}} = Plc.request_operation_signature(user)
    token
  end

  defp stored_operation(user), do: JSON.decode!(Accounts.get_user(user.did).plc_operation)

  defp spent_tokens(user) do
    from(t in Token,
      where: t.did == ^user.did and t.purpose == :plc_operation and not is_nil(t.used_at)
    )
    |> Repo.all()
  end

  defp account_key_did(user) do
    {:ok, key} = Keys.ensure(user.did)
    Did.key_did(key.pub)
  end

  defp error_name(conn), do: JSON.decode!(conn.resp_body)["error"]

  defp json_body(conn) do
    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp put_identity(identity), do: put_env(:identity, identity)

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
