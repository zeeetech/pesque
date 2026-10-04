defmodule Pesque.RateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Pesque.RateLimit
  alias PesqueWeb.Plugs.RateLimit, as: Plug

  @limits Plug.init(bucket: :test, limit: 2, window: 60_000)

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
    assert get_resp_header(conn, "ratelimit-reset") == ["60"]
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

  defp call(address, opts \\ []) do
    forwarded = Keyword.get(opts, :forwarded, address)
    Plug.call(request(forwarded, opts), @limits)
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

  defp unique, do: {__MODULE__, System.unique_integer([:positive])}
end
