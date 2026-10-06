defmodule Pesque.RateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Pesque.RateLimit
  alias PesqueWeb.Plugs.RateLimit, as: Plug

  @limits Plug.init(bucket: :test, limit: 2, window: 60_000)
  @session_limits Plug.init(bucket: :session, limit: 2, window: 60_000)
  @read_limits Plug.init(bucket: :read, limit: 2, window: 60_000)

  # The counter table is named, not owned, so a test can measure what a request
  # put into it.
  @table :pesque_rate_limit

  test "a call inside the limit is counted and one past it is refused" do
    key = unique()

    assert {:ok, 1} = RateLimit.hit(key, 2, 60_000)
    assert {:ok, 2} = RateLimit.hit(key, 2, 60_000)
    assert {:error, retry} = RateLimit.hit(key, 2, 60_000)
    assert retry in 1..60_000
  end

  # Fixed windows reset on a boundary, so without the reset the counters would
  # only ever fill up and every account would be locked out forever.
  test "a window that has passed starts over" do
    key = unique()

    assert {:ok, 1} = RateLimit.hit(key, 1, 20)
    assert {:error, _retry} = RateLimit.hit(key, 1, 20)

    Process.sleep(40)

    assert {:ok, 1} = RateLimit.hit(key, 1, 20)
  end

  test "two keys are counted apart" do
    assert {:ok, 1} = RateLimit.hit({:account, unique()}, 1, 60_000)
    assert {:ok, 1} = RateLimit.hit({:address, unique()}, 1, 60_000)
  end

  test "a call inside the limit passes through and says what is left" do
    conn = call("203.0.113.7")

    refute conn.halted
    assert get_resp_header(conn, "ratelimit-limit") == ["2"]
    assert get_resp_header(conn, "ratelimit-remaining") == ["1"]
    [reset] = get_resp_header(conn, "ratelimit-reset")
    assert String.to_integer(reset) in 1..60
  end

  # Remaining is read after the hit, not before it. A plug that counted twice
  # would spend the budget at half the advertised rate without ever refusing.
  test "a second call reports one less" do
    call("203.0.113.8")
    conn = call("203.0.113.8")

    assert get_resp_header(conn, "ratelimit-remaining") == ["0"]
  end

  test "a call past the limit is a 429 with a retry-after" do
    call("203.0.113.9")
    call("203.0.113.9")
    conn = call("203.0.113.9")

    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert JSON.decode!(conn.resp_body)["error"] == "RateLimitExceeded"
  end

  # Behind Caddy every request arrives from the proxy, so the socket address
  # would be one bucket the whole server shares.
  test "the forwarded address is the one that is counted" do
    call("203.0.113.10", forwarded: "198.51.100.1")
    call("203.0.113.10", forwarded: "198.51.100.1")

    refute call("203.0.113.10", forwarded: "198.51.100.2").halted
  end

  # The spec counts both, and they are counted in one pass: a limit met by the
  # account refuses even when the address has budget left.
  test "an account and an address are two keys, not one" do
    options = [did: "did:web:a"]

    refute call("203.0.113.11", options).halted
    refute call("203.0.113.11", options).halted
    assert call("203.0.113.11", options).halted
  end

  # createAccount takes handle, not identifier, so keying the account on
  # identifier alone left it counted on the spoofable address alone. Rotating
  # x-forwarded-for used to lift the ceiling entirely on an endpoint that runs
  # argon2 and claims a keypair.
  test "rotating the forwarded address does not lift the createAccount limit" do
    params = %{
      "handle" => "alice.test",
      "email" => "alice@example.com",
      "password" => "hunter2hunter2"
    }

    for address <- ~w(203.0.113.20 203.0.113.21) do
      refute create_account_call(address, params).halted
    end

    assert create_account_call("203.0.113.22", params).halted
  end

  # The invite code is what a closed registration makes scarce, so it is a
  # budget of its own rather than a field of the handle's: a code spent on three
  # different handles has bought three accounts, which is what the code's use
  # count is for.
  test "an invite code is a budget of its own" do
    one = %{"handle" => "bob.test", "inviteCode" => "invite-one"}
    two = %{"handle" => "carol.test", "inviteCode" => "invite-two"}

    refute session_call("203.0.113.23", one).halted
    refute session_call("203.0.113.24", one).halted
    assert session_call("203.0.113.25", one).halted

    refute session_call("203.0.113.26", two).halted
  end

  # Every route in the read scope is an unauthenticated GET with a repo or a
  # did in it and no identifier, which made identifier the wrong param to key
  # on for the whole class.
  test "a read is counted on its repo" do
    params = %{"repo" => "did:plc:alice", "collection" => "app.bsky.feed.post"}

    for address <- ~w(203.0.113.30 203.0.113.31) do
      refute read_call(address, params).halted
    end

    assert read_call("203.0.113.32", params).halted
    refute read_call("203.0.113.33", %{"repo" => "did:plc:bob"}).halted
  end

  test "a read is counted on its did" do
    params = %{"did" => "did:web:carol.test"}

    for address <- ~w(203.0.113.34 203.0.113.35) do
      refute read_call(address, params).halted
    end

    assert read_call("203.0.113.36", params).halted
  end

  # Each param is its own budget, so naming the account a different way does not
  # buy another window's worth of requests on the first.
  test "an identifier and a handle are separate budgets" do
    refute session_call("203.0.113.40", %{"identifier" => "dana@example.com"}).halted
    refute session_call("203.0.113.41", %{"handle" => "erin.test"}).halted
    refute session_call("203.0.113.42", %{"handle" => "erin.test"}).halted
    assert session_call("203.0.113.43", %{"handle" => "erin.test"}).halted
  end

  # The body parser allows megabytes and x-forwarded-for ten kilobytes, and both
  # used to become ETS keys verbatim. What lands in the table has to be a fixed
  # width, so this asserts on the stored keys rather than on how much memory
  # happened to move.
  test "an oversized identifier and header do not land oversized keys" do
    identifier = String.duplicate("a", 1_000_000)
    forwarded = String.duplicate("9", 10_000)

    for address <- ~w(203.0.113.50 203.0.113.51) do
      refute create_account_call(address, %{"identifier" => identifier}, forwarded: forwarded).halted
    end

    # Asserted over the whole table rather than over this test's rows: the
    # table is shared and these run async, and nothing anywhere in it is
    # allowed to hold caller-supplied bytes. A megabyte identifier stored
    # verbatim is a megabyte per request, and this is the assertion that fails.
    assert Enum.all?(:ets.tab2list(@table), &bounded?/1)
  end

  # A digest, not the string: two identifiers that share a prefix are two
  # budgets, so a caller who knows an identifier cannot pad their way into
  # someone else's allowance.
  test "an identifier is keyed on its digest" do
    plain = %{"identifier" => "frank@example.com"}
    padded = %{"identifier" => "frank@example.comXXXX"}

    refute session_call("203.0.113.60", plain).halted
    refute session_call("203.0.113.61", padded).halted
    refute session_call("203.0.113.62", plain).halted
    assert session_call("203.0.113.63", plain).halted
  end

  # The counter is one atomic ETS operation. A read-then-write would let the
  # first hundred of these run concurrently and all answer ok, which no
  # sequential assertion above would catch.
  test "the counter is atomic under concurrency" do
    key = unique()

    results =
      1..200
      |> Task.async_stream(fn _ -> RateLimit.hit(key, 100, 60_000) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 100
    assert Enum.count(results, &match?({:error, _}, &1)) == 100
  end

  defp call(address, opts \\ []) do
    forwarded = Keyword.get(opts, :forwarded, address)
    Plug.call(request(forwarded, opts), @limits)
  end

  # createAccount and the read routes cannot be reached through the router
  # without a limit small enough to be worth asserting on, and the router is
  # not this test's to wire. The plug is the whole of the limiter's behaviour,
  # so the request is built the way those routes build it.
  defp create_account_call(address, params, opts \\ []) do
    Plug.call(post(address, params, opts), @session_limits)
  end

  defp session_call(address, params), do: create_account_call(address, params)

  defp read_call(address, params) do
    Plug.call(get(address, params), @read_limits)
  end

  defp post(address, params, opts) do
    conn(:post, "/", params)
    |> put_req_header("x-forwarded-for", Keyword.get(opts, :forwarded, address))
  end

  defp get(address, params) do
    conn(:get, "/", params)
    |> put_req_header("x-forwarded-for", address)
  end

  defp request(address, opts) do
    conn(:get, "/")
    |> put_req_header("x-forwarded-for", address)
    |> then(fn conn ->
      case Keyword.get(opts, :did) do
        nil -> conn
        did -> assign(conn, :did, did)
      end
    end)
  end

  defp bounded?(row) do
    {{key, _window}, _count, _window_ms} = row
    key |> :erlang.term_to_binary() |> byte_size() <= 128
  end

  defp unique, do: {__MODULE__, System.unique_integer([:positive])}
end
