defmodule Pesque.AccountIdentifierTest do
  use Pesque.DataCase, async: false

  import Ecto.Query

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Repo

  @password "hunter2hunter2"

  setup do
    put_mode(:multi)
  end

  # An account's DID is minted once, at creation. did:web percent-encodes a
  # non-default port, so re-deriving the DID from the config the server runs
  # on today means moving from port 4000 to 443 makes every stored account
  # unreachable: intact rows, and every read answering RepoNotFound.
  test "an account stays reachable after the server moves to another port" do
    user =
      insert_account("alice")

    put_port(443)

    assert Accounts.repo_did(user.did) == {:ok, user.did}
    assert Accounts.repo_did(user.handle) == {:ok, user.did}
    assert Accounts.get_user(user.did)
  end

  # Matching the stored row instead of re-deriving is what makes the port
  # irrelevant, and matching a stored row is what keeps a remote identifier
  # from resolving to anything.
  test "a did or handle belonging to another network still resolves to nothing" do
    insert_account("alice")

    assert Accounts.repo_did("did:web:evil.example:user:alice") == {:error, :not_found}
    assert Accounts.repo_did("alice.bsky.social") == {:error, :not_found}
    assert Accounts.repo_did("nobody.localhost") == {:error, :not_found}
    assert Accounts.repo_did(nil) == {:error, :invalid_identifier}
  end

  # The collision is reachable unauthenticated: the string names one account
  # by handle and another by email, and login has to answer for it instead of
  # raising. The rows are inserted directly because create_account/3 refuses
  # to make them, which is the point of the refusal.
  test "a string that is one account's handle and another's email does not raise" do
    victim = insert_account("victim")
    other = insert_account("other")
    insert_account("impostor", victim.handle)

    assert {:ok, %User{did: did, handle: handle}} =
             Accounts.verify_login(victim.handle, @password)

    assert did == victim.did
    assert handle == victim.handle
    refute did == other.did

    assert :error = Accounts.verify_login(victim.handle, "wrong-password")

    for _ <- 1..3 do
      assert {:ok, %User{did: ^did}} = Accounts.verify_login(victim.handle, @password)
    end
  end

  # Tangled opens the OAuth flow with the DID as login_hint, and the check that
  # accepts a hint (repo_did/1) accepts a did. Login has to resolve the same
  # shapes, or the hint check passes and the login it guards then answers
  # invalid credentials for a correct password.
  test "login resolves a did the way the login_hint check does" do
    user = insert_account("alice")

    assert {:ok, %User{did: did}} = Accounts.verify_login(user.did, @password)
    assert did == user.did
  end

  # A handle is case-insensitive on the wire, so a hint in different casing has
  # to name the account repo_did/1 said it names instead of falling through.
  test "login resolves a handle case-insensitively" do
    user = insert_account("alice")

    assert {:ok, %User{did: did}} = Accounts.verify_login(String.upcase(user.handle), @password)
    assert did == user.did
  end

  # single's stored handle is Pesque.handle_domain/0, and repo_did/1
  # downcases the query, so a domain written with capitals has to come back
  # lowercase or the account it minted is unreachable.
  test "handle_domain is normalized to lowercase" do
    previous = Application.get_env(:pesque, :handle_domain)
    Application.put_env(:pesque, :handle_domain, "Example.COM")

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:pesque, :handle_domain),
        else: Application.put_env(:pesque, :handle_domain, previous)
    end)

    assert Pesque.handle_domain() == "example.com"
  end

  test "an email equal to an existing handle is refused" do
    victim = insert_account("victim")
    before = key_files()

    assert {:error, :email_taken} =
             Accounts.create_account(unique("alice") <> ".localhost", victim.handle, @password)

    assert key_files() == before
  end

  test "a handle equal to an existing email is refused" do
    # An email that is also a syntactically valid handle, which is the only
    # way the reverse direction is reachable through create_account/3.
    handle = unique("collide") <> ".localhost"
    insert_account("holder", handle)
    before = key_files()

    assert {:error, :handle_not_available} =
             Accounts.create_account(handle, unique("a") <> "@localhost", @password)

    assert key_files() == before
  end

  defp insert_account(name, email \\ nil) do
    username = unique(name)
    # A unique did:plc per account. Multi accounts are did:plc, minted by the
    # directory; the derived host DID would collide across inserted rows.
    did = "did:plc:" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    user =
      Repo.insert!(
        User.changeset(%{
          did: did,
          handle: username <> ".localhost",
          username: username,
          pubkey_multibase: "z" <> username,
          email: email || unique("mail") <> "@localhost",
          password_hash: Argon2.hash_pwd_salt(@password)
        })
      )

    on_exit(fn -> Repo.delete_all(from u in User, where: u.id == ^user.id) end)
    user
  end

  defp put_port(port) do
    previous = Application.get_env(:pesque, :port)

    on_exit(fn -> Application.put_env(:pesque, :port, previous) end)

    Application.put_env(:pesque, :port, port)
    :ok
  end

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  defp key_files, do: Pesque.Storage.keys_dir() |> File.ls!() |> Enum.sort()

  defp unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
