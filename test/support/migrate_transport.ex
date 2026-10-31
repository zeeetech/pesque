defmodule Pesque.Migrate.TestTransport do
  @moduledoc """
  The plain transport the migration client's socket tests speak through.

  `Pesque.OAuth.Fetch` is what production uses, and it refuses anything but a
  public https address, which a throwaway server on loopback is not. The tests
  that drive `Pesque.Migrate.Http` at the socket inject this instead: the raw
  `Pesque.HTTP` boundary with no scheme or address check, and the long timeout
  a socket test wants. What they assert is still the request line the client
  sends and the redirect it follows, and the policy stays where it belongs.
  """

  alias Pesque.HTTP

  @connect_timeout 5_000
  @timeout 30_000

  @doc "Makes one request and answers the shape `Pesque.OAuth.Fetch.request/5` does."
  def request(%URI{} = uri, method, headers, body, _opts) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    HTTP.request(uri, method, headers, body,
      connect_timeout: @connect_timeout,
      timeout: @timeout
    )
  end
end
