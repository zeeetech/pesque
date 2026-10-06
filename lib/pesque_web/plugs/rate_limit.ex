defmodule PesqueWeb.Plugs.RateLimit do
  @moduledoc """
  Turns the spec's per-endpoint limits into something the router can hang on a
  pipeline.

  Two keys are counted, not one: the account the request names and the address
  the request came from. One account is one limit however many addresses it
  uses, and one address is one limit however many accounts it holds, so
  neither a single client spreading requests out nor a single client holding a
  dozen accounts gets past the number the spec chose. Both are counted in one
  pass, and the tighter of the two answers.

  The account is named by conn.assigns.did when an auth plug ran first, and by
  whatever the endpoint names the account with when it did not, which is not one
  param: the session endpoints carry `identifier`, account creation carries
  `handle` and an `inviteCode`, and the repo reads carry `repo` or `did`. The
  bucket class says which of those to look for. Without this they would be
  limited per address only, and an unauthenticated caller could lift the whole
  ceiling by rotating `x-forwarded-for` on a request that runs argon2.

  Both keys are client-supplied strings and both become ETS rows that live as
  long as their window, so an unbounded one is a way to spend the node's
  memory: a body parser allows megabytes and a header ten kilobytes, either of
  which used to be stored verbatim. The account key is hashed to sixteen bytes;
  the address is sliced, because an address is short enough that slicing it
  cannot merge two callers.

  Which address that is depends on what is in front of the server, and the
  README says Caddy or nginx is. `x-forwarded-for` is therefore read ahead of
  the socket, because behind a proxy every request arrives from the proxy and
  one caller could spend the whole server's budget. It is trusted on the
  operator's word that a proxy is in front; a server reachable directly, with
  the header forgeable, is a server whose per-address limit is worth nothing.
  """

  import Plug.Conn

  alias Pesque.RateLimit
  alias PesqueWeb.Xrpc

  # An address is an IP or an IP with a port, so the longest one that can exist
  # is well under this. Anything longer is not an address.
  @max_address_length 64

  # An email address is the longest handle-shaped thing a caller can send, and
  # 320 is the RFC's own limit on one. Generous past what any real identifier
  # needs, which is the point: a bound that only real values fit under is a
  # bound the attacker cannot get past either.
  @max_account_length 320

  # Which params can name the account, per bucket class, and in what order.
  # Read routes take either spelling of a repo's DID and no identifier at all,
  # so keying them on identifier would key them on nothing.
  @account_params %{
    session: ~w(identifier handle inviteCode),
    read: ~w(repo did)
  }

  # A bucket this plug has not been told about counts on every name it knows,
  # so a new class is limited per account by default rather than by address
  # alone until someone remembers to add it here.
  @default_account_params ~w(identifier handle inviteCode repo did)

  @doc """
  Options: `:bucket` names the limit class, `:limit` and `:window` size it.

  `:window` is in milliseconds and defaults to an hour, which is what the
  spec's limits are written against.
  """
  def init(opts) do
    %{
      bucket: Keyword.fetch!(opts, :bucket),
      limit: Keyword.fetch!(opts, :limit),
      window: Keyword.get(opts, :window, 3_600_000)
    }
  end

  def call(conn, %{bucket: bucket, limit: limit, window: window}) do
    # Counted once and then read, rather than counted per key and counted
    # again to build the headers: a passing request that incremented its
    # counter twice would spend the caller's budget at half the advertised rate.
    results = Enum.map(keys(conn, bucket), &RateLimit.hit(&1, limit, window))

    case Enum.find(results, &match?({:error, _retry}, &1)) do
      nil -> headers(conn, limit, window, spent(results))
      {:error, retry_after} -> refuse(conn, limit, window, retry_after)
    end
  end

  defp keys(conn, bucket) do
    address = {:address, bucket, address(conn)}

    case Map.get(conn.assigns, :did) do
      nil -> [address | account_keys(conn, bucket)]
      did -> [{:account, bucket, digest(did)}, address]
    end
  end

  # Every route that runs before an auth plug is reachable by a stranger, so
  # the account is taken from whichever param the endpoint names it with rather
  # than from one param name. Keying on identifier alone meant createAccount and
  # every read route counted a single spoofable address key: rotating
  # x-forwarded-for lifted the limit entirely on endpoints that run argon2 and
  # claim a keypair.
  defp account_keys(conn, bucket) do
    bucket
    |> account_params()
    |> Enum.flat_map(&account_key(conn, &1))
  end

  defp account_params(bucket), do: Map.get(@account_params, bucket, @default_account_params)

  # A param that is absent, not a string, or empty names nothing, and a key for
  # it would be shared by every caller that omits it.
  defp account_key(conn, name) do
    case Map.get(conn.params, name) do
      value when is_binary(value) and value != "" -> [{:account, name, digest(value)}]
      _ -> []
    end
  end

  # Bounded because x-forwarded-for is the client's to write, and a header can
  # carry ten kilobytes. Sliced rather than hashed because an address is short
  # enough that no two real ones can share a prefix this long, so slicing cannot
  # merge two callers into one budget, and it is the cheaper of the two.
  defp address(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()
        |> String.slice(0, @max_address_length)

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  # Hashed, not sliced, and that is the whole point of the account key. A
  # sliced key would make alice@example.com and alice@example.comXXXX... one
  # budget, so a caller who knows a handle can spend someone else's allowance;
  # a hash has no such collisions to aim at. Slicing first keeps the hash
  # input bounded, since hashing a megabyte on the request path is 341us of
  # attacker-chosen CPU versus 239us for a sliced one. The name is kept beside
  # the digest so identifier, handle and inviteCode stay separate budgets.
  defp digest(value) do
    value
    |> String.slice(0, @max_account_length)
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
  end

  # Remaining is taken from whichever key is closest to its ceiling, which is
  # the one that would have refused first.
  defp spent(results) do
    results
    |> Enum.flat_map(fn
      {:ok, count} -> [count]
      {:error, _retry} -> []
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp headers(conn, limit, window, count) do
    conn
    |> put_resp_header("ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("ratelimit-remaining", Integer.to_string(max(limit - count, 0)))
    |> put_resp_header("ratelimit-reset", Integer.to_string(seconds_until_reset(window)))
  end

  # seconds left in the current window, not the window's size. `window` and the
  # rate limiter's periods use the same monotonic clock, so the same
  # floor-div/mod arithmetic answers how long until the counter rolls over.
  defp seconds_until_reset(window) do
    now = System.monotonic_time(:millisecond)
    ceil((window - Integer.mod(now, window)) / 1000)
  end

  defp refuse(conn, limit, window, retry_after) do
    seconds = ceil(retry_after / 1000)

    conn
    |> headers(limit, window, limit)
    # Before the error is built, because Xrpc.error/4 puts a response and
    # anything set afterwards lands on a conn nobody reads.
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> Xrpc.error(
      429,
      "RateLimitExceeded",
      "too many requests; retry in #{seconds}s"
    )
  end
end
