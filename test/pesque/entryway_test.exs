defmodule Pesque.EntrywayTest do
  @moduledoc """
  The entryway shell: resolve, mint, fetch, normalize. The resolver and the
  fetcher are injected, so no test reaches the network.
  """

  use ExUnit.Case, async: false

  alias Pesque.Accounts
  alias Pesque.Entryway
  alias Pesque.Entryway.Call
  alias Pesque.Entryway.Response

  @target "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @nsid "app.bsky.feed.getTimeline"
  @endpoint "https://api.bsky.app"

  # The injected primitives answer whatever the test stored and tell the test
  # process they were called, so a call refused before resolution is observable
  # as an absent message.
  defmodule Directory do
    def resolve(did) do
      notify({:directory, did})
      :persistent_term.get(:entryway_test_document, {:error, :not_found})
    end

    defp notify(message) do
      case :persistent_term.get(:entryway_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  defmodule Fetch do
    def request(uri, method, headers, body, opts) do
      notify({:fetch, uri, method, headers, body, opts})

      :persistent_term.get(
        :entryway_test_response,
        {:ok, 200, [{"content-type", "application/json"}], "{}"}
      )
    end

    defp notify(message) do
      case :persistent_term.get(:entryway_test_pid, nil) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  setup do
    Pesque.DataCase.setup()
    put_mode(:path_multi)

    :persistent_term.put(:entryway_test_pid, self())
    :persistent_term.put(:entryway_test_document, {:ok, document(@target)})
    Application.put_env(:pesque, :did_resolver_directory, Directory)
    Application.put_env(:pesque, :entryway_fetch, Fetch)

    on_exit(fn ->
      :persistent_term.erase(:entryway_test_pid)
      :persistent_term.erase(:entryway_test_document)
      :persistent_term.erase(:entryway_test_response)
      Application.delete_env(:pesque, :did_resolver_directory)
      Application.delete_env(:pesque, :entryway_fetch)
    end)

    %{user: account()}
  end

  test "forwards a call to the service the header names", %{user: user} do
    assert {:ok, %Response{status: 200, body: "{}"}} = Entryway.forward(call(), user.did)

    assert_received {:fetch, uri, :get, headers, nil, opts}
    assert URI.to_string(uri) == "https://api.bsky.app/xrpc/app.bsky.feed.getTimeline"
    assert opts[:max_bytes] == Pesque.proxy_response_limit()
    assert opts[:timeout] == Pesque.proxy_timeout()

    claims = headers |> authorization_token() |> decode_claims()
    assert claims["iss"] == user.did
    assert claims["aud"] == @target
    assert claims["lxm"] == @nsid
  end

  test "carries the query string and the body through", %{user: user} do
    assert {:ok, %Response{}} =
             Entryway.forward(
               call(%{method: :post, query: "a=1", body: ~s({"x":1})}),
               user.did
             )

    assert_received {:fetch, uri, :post, _headers, ~s({"x":1}), _opts}
    assert uri.query == "a=1"
  end

  test "a directory failure is a proxy_target_unresolved", %{user: user} do
    :persistent_term.put(:entryway_test_document, {:error, :not_found})

    assert Entryway.forward(call(), user.did) == {:error, :proxy_target_unresolved}
  end

  test "a document with no such service is service_not_found", %{user: user} do
    :persistent_term.put(:entryway_test_document, {:ok, %{"id" => @target, "service" => []}})

    assert Entryway.forward(call(), user.did) == {:error, :service_not_found}
  end

  test "fetch failures are normalized", %{user: user} do
    for {reason, expected} <- [
          {:forbidden_address, :proxy_forbidden_address},
          {:timeout, :proxy_timeout},
          {:body_too_big, :proxy_response_too_large},
          {:body_too_large, :proxy_response_too_large},
          {:econnrefused, :proxy_unreachable}
        ] do
      :persistent_term.put(:entryway_test_response, {:error, reason})

      assert Entryway.forward(call(), user.did) == {:error, expected}
    end
  end

  test "a missing proxy header is answered before anything is resolved", %{user: user} do
    assert Entryway.forward(call(%{proxy: nil}), user.did) == {:error, :missing_proxy}
    refute_received {:directory, _}
    refute_received {:fetch, _, _, _, _, _}
  end

  test "an invalid method name is answered before anything is resolved", %{user: user} do
    assert Entryway.forward(call(%{nsid: "not-an-nsid"}), user.did) == {:error, :invalid_nsid}
    refute_received {:directory, _}
    refute_received {:fetch, _, _, _, _, _}
  end

  defp call(overrides \\ %{}) do
    struct!(
      Call,
      Map.merge(
        %{
          method: :get,
          nsid: @nsid,
          proxy: @target <> "#bsky_appview",
          query: "",
          body: nil,
          headers: [{"accept", "application/json"}]
        },
        overrides
      )
    )
  end

  defp document(did) do
    %{
      "id" => did,
      "service" => [
        %{
          "id" => did <> "#bsky_appview",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => @endpoint
        }
      ]
    }
  end

  defp account do
    username = "entryway" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    {:ok, user} =
      Accounts.create_account(
        username <> ".localhost",
        username <> "@localhost",
        "hunter2hunter2"
      )

    user
  end

  defp authorization_token(headers) do
    case List.keyfind(headers, "authorization", 0) do
      {"authorization", "Bearer " <> token} -> token
      other -> flunk("no bearer token in #{inspect(other)}")
    end
  end

  defp decode_claims(token) do
    [_, payload, _signature] = String.split(token, ".")

    payload
    |> Base.url_decode64!(padding: false)
    |> JSON.decode!()
  end

  defp put_mode(mode) do
    previous = Application.get_all_env(:pesque)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:pesque, key, value) end)
    end)

    Application.put_env(:pesque, :mode, mode)
    :ok
  end
end
