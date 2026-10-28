defmodule PesqueWeb.ConnCase do
  @moduledoc """
  Isolation for tests that go through the endpoint.

  `Pesque.DataCase` owns the database, the key files, the blobs and the live
  RepoServers. Account fixtures are deliberately split by what a test needs:
  `create_account/1` exercises the real creation path without starting a repo,
  `insert_account/2` inserts background state without PLC or Argon2, and
  `start_repo/1` adds a signing key and genesis commit. `create_repo_account/1`
  composes real creation with a running repo; `insert_repo_account/1` composes
  a persisted row with a running repo.

  Use the lightest fixture that proves the behavior. The direct fixture's
  password hash and public key are test-only constants; request-flow tests that
  exercise creation, password hashing, PLC, or key placement must use the real
  creation path instead.

  The helpers stop at `dispatch/4` and hand back the conn, so a test that needs
  a header these do not set puts it in its own pipe.

  Every request carries the same `x-request-id`. Pinning it costs nothing and
  makes two error responses comparable header by header, which is how a test
  tells "the same failure twice" from "two different failures" without
  reaching into anything else.
  """

  use ExUnit.CaseTemplate

  import Phoenix.ConnTest
  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Base32
  alias Pesque.Keys
  alias Pesque.Repo
  alias Pesque.RepoServer
  alias PesqueWeb.Endpoint

  using do
    quote do
      import PesqueWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn

      alias Pesque.Accounts
      alias Pesque.RepoServer
      alias PesqueWeb.Endpoint
    end
  end

  setup tags do
    Pesque.DataCase.setup_database(tags)
    put_mode(:multi)
    :ok
  end

  @password "hunter2hunter2"
  @password_hash "$argon2id$v=19$m=256,t=1,p=4$ZXUef5WOzZuMy8jxlKMpfg$11wxlt7DLrzD/6DIIqrNycHiZtRyY/Dzg5BlYDCeFY8"
  @fixture_pubkey "zQ3shYkUJ2lPvBNGaJmZJXGPFYqQCnEBWcVGY7DKZqFmVKZ"
  @collection "app.bsky.feed.post"
  @request_id "0123456789abcdef0123456789abcdef"

  @doc "Creates an account through Accounts.create_account/4 without starting its repo."
  def create_account(name) do
    username = unique(name)

    {:ok, user} =
      Accounts.create_account(username <> ".localhost", username <> "@localhost", @password)

    user
  end

  @doc "Creates and persists an account row directly, without PLC or password hashing."
  def insert_account(name, opts \\ []) do
    username = unique(name)
    did = "did:plc:" <> String.downcase(Base32.encode(:crypto.strong_rand_bytes(15)))

    key =
      if Keyword.get(opts, :key, false) do
        {:ok, key} = Keys.create_exclusive(did)
        key
      end

    Repo.insert!(
      User.changeset(%{
        did: did,
        handle: username <> ".localhost",
        username: username,
        email: username <> "@localhost",
        password_hash: @password_hash,
        pubkey_multibase: if(key, do: key.pub_multibase, else: @fixture_pubkey)
      })
    )
  end

  @doc "Starts a repo for an account, ensuring it has a signing key first."
  def start_repo(user) do
    {:ok, key} = Keys.ensure(user.did)

    user =
      if user.pubkey_multibase == key.pub_multibase do
        user
      else
        user
        |> Ecto.Changeset.change(pubkey_multibase: key.pub_multibase)
        |> Repo.update!()
      end

    # A call round trip, not the pid, guarantees the genesis commit in
    # handle_continue/2 has already run.
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    RepoServer.entries(pid)

    user
  end

  @doc "Creates an account through the domain, then starts its repo."
  def create_repo_account(name), do: name |> create_account() |> start_repo()

  @doc "Inserts a persisted account fixture with a key and starts its repo."
  def insert_repo_account(name), do: name |> insert_account(key: true) |> start_repo()

  @doc "An access token for an account."
  def token(user) do
    {:ok, session} = Accounts.issue_session(user.did)
    session.access_jwt
  end

  @doc "A record that the post lexicon accepts."
  def post_record(text) do
    %{
      "$type" => @collection,
      "text" => text,
      "createdAt" => "2026-01-01T00:00:00.000Z"
    }
  end

  @doc "The collection the post helpers write to."
  def collection, do: @collection

  def xrpc_get(path, token \\ nil), do: request(:get, path, nil, token)

  def xrpc_post(path, params, token), do: request(:post, path, JSON.encode!(params), token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("x-request-id", @request_id)
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(token)
    |> dispatch(Endpoint, method, path, body)
  end

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  @doc "Switches did:web mode for the test, putting it back afterwards."
  def put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end

  def enc(value), do: URI.encode_www_form(value)

  def unique(prefix), do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
