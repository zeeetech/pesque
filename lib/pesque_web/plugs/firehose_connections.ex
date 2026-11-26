defmodule PesqueWeb.Plugs.FirehoseConnections do
  @moduledoc false

  alias Pesque.FirehoseConnections
  alias PesqueWeb.Plugs.RateLimit
  alias PesqueWeb.Xrpc

  def init(opts), do: opts

  def call(conn, _opts) do
    case FirehoseConnections.admit(RateLimit.client_address(conn)) do
      :ok ->
        conn

      {:error, :ip_limit} ->
        Xrpc.error(
          conn,
          429,
          "FirehoseConnectionLimitExceeded",
          "too many firehose connections from this address"
        )

      {:error, :global_limit} ->
        Xrpc.error(
          conn,
          503,
          "FirehoseUnavailable",
          "firehose connection capacity is exhausted"
        )
    end
  end
end
