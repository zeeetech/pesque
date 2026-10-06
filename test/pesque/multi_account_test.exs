defmodule Pesque.MultiAccountTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Base58
  alias Pesque.CBOR
  alias Pesque.Did
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias Pesque.RepoStore
  alias Pesque.Secp256k1

  @password "hunter2hunter2"

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
  end

  test "two accounts get their own did, handle, key, and document" do
    alice = create("alice")
    bob = create("bob")

    refute alice.did == bob.did
    refute alice.handle == bob.handle
    refute alice.pubkey_multibase == bob.pubkey_multibase

    assert alice.did == Did.did_for_username(:path_multi, host(), alice.username)
    assert Did.path_for_did(alice.did) == "/user/#{alice.username}/did.json"

    assert {:ok, alice_doc} = Accounts.did_document_for(alice.username)
    assert {:ok, bob_doc} = Accounts.did_document_for(bob.username)

    assert alice_doc["id"] == alice.did
    assert alice_doc["alsoKnownAs"] == ["at://" <> alice.handle]
    assert bob_doc["alsoKnownAs"] == ["at://" <> bob.handle]

    assert published(alice_doc) == alice.pubkey_multibase
    assert published(bob_doc) == bob.pubkey_multibase
    refute published(alice_doc) == published(bob_doc)
  end

  test "each account signs with the key it publishes, and with no other" do
    alice = create("alice")
    bob = create("bob")

    {:ok, _} = RepoServer.create_record(repo(alice), "app.bsky.feed.post", "1", post("alice"))
    {:ok, _} = RepoServer.create_record(repo(bob), "app.bsky.feed.post", "1", post("bob"))

    {:ok, alice_doc} = Accounts.did_document_for(alice.username)
    {:ok, bob_doc} = Accounts.did_document_for(bob.username)

    assert verifies?(alice.did, published(alice_doc), payload(alice.did)), "own key"
    assert verifies?(bob.did, published(bob_doc), payload(bob.did)), "own key"

    refute verifies?(alice.did, published(bob_doc), payload(alice.did)), "the other account's key"
    refute verifies?(bob.did, published(alice_doc), payload(bob.did)), "the other account's key"

    # A verifier that accepts everything proves nothing, so the payload is
    # broken on purpose and must stop verifying.
    refute verifies?(alice.did, published(alice_doc), payload(alice.did) <> <<0>>),
           "tampered payload"
  end

  test "resolve_handle answers for every local account and for nothing else" do
    alice = create("alice")
    bob = create("bob")

    assert Accounts.resolve_handle(alice.handle) == {:ok, alice.did}
    assert Accounts.resolve_handle(bob.handle) == {:ok, bob.did}

    assert Accounts.resolve_handle("carol.localhost") == {:error, :not_found}
    assert Accounts.resolve_handle("alice.notlocalhost") == {:error, :not_found}
    assert Accounts.resolve_handle("alice.localhost.evil.com") == {:error, :not_found}
    assert Accounts.resolve_handle("localhost") == {:error, :not_found}
  end

  test "a handle under a lookalike domain is rejected and claims no key file" do
    before = key_files()

    assert {:error, :handle_not_available} =
             Accounts.create_account("alice.notlocalhost", "a@localhost", @password)

    assert key_files() == before
  end

  # An orphan key file makes the next attempt at the handle fail on the
  # exclusive create, so the retry is the thing that has to work.
  test "a failed insert removes the key file and leaves the handle retryable" do
    username = unique("alice")
    did = Did.did_for_username(:path_multi, host(), username)

    other = insert_user()

    assert {:error, :email_taken} =
             Accounts.create_account(username <> ".localhost", other.email, @password)

    refute File.exists?(Keys.path(did)), "key file left behind by the failed insert"

    assert {:ok, user} =
             Accounts.create_account(
               username <> ".localhost",
               unique("retry") <> "@localhost",
               @password
             )

    assert user.did == did
    assert File.exists?(Keys.path(did))
  end

  test "two concurrent createAccount calls for one handle yield one account" do
    username = unique("alice")
    handle = username <> ".localhost"
    before = key_files()

    results =
      [1, 2]
      |> Enum.map(fn i ->
        Task.async(fn ->
          Accounts.create_account(handle, "#{i}-#{unique("racer")}@localhost", @password)
        end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _user}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :handle_not_available})) == 1

    assert Repo.aggregate(from(u in User, where: u.handle == ^handle), :count, :id) == 1

    did = Did.did_for_username(:path_multi, host(), username)
    assert key_files() -- before == [Path.basename(Keys.path(did))]
  end

  # conformant_single is single account by design, and its one account is the
  # server, so it signs with the key boot already published for the server DID.
  test "conformant_single still admits exactly one account" do
    put_mode(:conformant_single)

    assert {:ok, user} =
             Accounts.create_account("localhost", unique("a") <> "@localhost", @password)

    assert user.username == nil
    assert user.pubkey_multibase == Pesque.Identity.public_key_multibase()

    on_exit(fn -> Repo.delete_all(from u in User, where: u.did == ^user.did) end)

    assert {:error, :account_exists} =
             Accounts.create_account("localhost", unique("b") <> "@localhost", @password)
  end

  defp published(doc) do
    [verification] = doc["verificationMethod"]
    verification["publicKeyMultibase"]
  end

  defp verifies?(did, pub_multibase, payload) do
    <<0xE7, 0x01, pub::binary>> = pub_multibase |> String.trim_leading("z") |> Base58.decode!()
    :crypto.verify(:ecdsa, :sha256, payload, Secp256k1.raw_to_der(sig(did)), [pub, :secp256k1])
  end

  defp payload(did), do: did |> commit() |> Map.delete("sig") |> CBOR.encode()
  defp sig(did), do: commit(did)["sig"].data

  defp commit(did) do
    cid = RepoStore.get_meta("commit:" <> did)

    did
    |> RepoStore.blocks_for()
    |> Enum.find_value(fn block -> if block.cid == cid, do: block.data end)
    |> CBOR.decode!()
  end

  test "create_account without an email is a tuple, not a raise" do
    # Reachable from the open createAccount endpoint. It used to reach
    # `u.handle == ^nil`, which Ecto refuses to build, so the crash escaped
    # the {:error, _} shape the endpoint maps and came out as a 500.
    #
    # Counted around the call rather than against an absolute zero: the sandbox
    # rolls back what this test wrote, but rows another test left behind in the
    # database are still there, and a zero here made the assertion a report on
    # the state of the file instead of on the behaviour under test.
    before = Repo.aggregate(User, :count)

    assert {:error, :email_required} =
             Accounts.create_account("alice.localhost", nil, @password)

    assert Repo.aggregate(User, :count) == before
  end

  test "one account's handle cannot be claimed as another's email" do
    create("alice")
    alice = Repo.one!(from u in User, where: like(u.username, "alice%"))

    assert {:error, :email_taken} =
             Accounts.create_account("bob.localhost", alice.handle, @password)
  end

  defp create(name) do
    username = unique(name)

    {:ok, user} =
      Accounts.create_account(username <> ".localhost", username <> "@localhost", @password)

    user
  end

  defp insert_user do
    username = unique("other")

    user =
      Repo.insert!(
        User.changeset(%{
          did: Did.did_for_username(:path_multi, host(), username),
          handle: username <> ".localhost",
          email: unique("taken") <> "@localhost",
          password_hash: "not-a-real-hash"
        })
      )

    on_exit(fn -> Repo.delete_all(from u in User, where: u.did == ^user.did) end)
    user
  end

  # A call round trip, not the pid, guarantees the genesis commit in
  # handle_continue/2 has already run.
  defp repo(user) do
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    RepoServer.entries(pid)
    pid
  end

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  defp host, do: Did.did_host(Pesque.hostname(), Pesque.port())

  defp key_files, do: Pesque.Storage.keys_dir() |> File.ls!() |> Enum.sort()

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp post(text) do
    %{"$type" => "app.bsky.feed.post", "text" => text, "createdAt" => "2026-01-01T00:00:00.000Z"}
  end
end
