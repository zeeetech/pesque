defmodule PesqueWeb.ConnCase do
  @moduledoc """
  Isolation for tests that go through the endpoint.

  `Pesque.DataCase` owns the database, the key files, the blobs and the live
  RepoServers. What is left is everything a request needs before a controller
  ever sees it: an account to write as, a token to write with, and the two
  request shapes the XRPC endpoints answer.

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

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)
    :ok
  end

  @password "hunter2hunter2"
  @collection "app.bsky.feed.post"
  @request_id "0123456789abcdef0123456789abcdef"

  @doc "An account, its repo running, and its handle."
  def create_account(name) do
    username = unique(name)

    {:ok, user} =
      Accounts.create_account(username <> ".localhost", username <> "@localhost", @password)

    # A call round trip, not the pid, guarantees the genesis commit in
    # handle_continue/2 has already run.
    {:ok, pid} = Pesque.RepoSupervisor.ensure_started(user.did)
    RepoServer.entries(pid)

    user
  end

  @doc "An access token for an account."
  def token(user), do: Accounts.issue_session(user.did).access_jwt

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
