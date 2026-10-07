defmodule Pesque.Entryway.Outbound do
  @moduledoc """
  The request the entryway will make on the client's behalf.

  Built by `Pesque.Entryway.Proxy.build_outbound/1`: the target service's
  endpoint merged with the method path and query, the headers to send, and the
  body if any.
  """

  @enforce_keys [:method, :uri, :headers]
  defstruct [:method, :uri, :headers, body: nil]

  # method: :get | :post
  # uri: %URI{} = service endpoint merged with /xrpc/<nsid> and the query
  # headers: [{"authorization", "Bearer <jwt>"}, {"accept", ...}, ...]
  # body: binary | nil
  @type t :: %__MODULE__{}
end
