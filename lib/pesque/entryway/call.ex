defmodule Pesque.Entryway.Call do
  @moduledoc """
  An inbound XRPC request the entryway is asked to forward.

  The shape is the client's request reduced to what the forwarding decision
  needs: the verb, the method name, the proxy header that names a target, the
  raw query string, the raw JSON body, and the request headers.
  """

  @enforce_keys [:method, :nsid, :proxy]
  defstruct [:method, :nsid, :proxy, query: "", body: nil, headers: []]

  # method: :get | :post
  # nsid: the XRPC method (the path after /xrpc/)
  # proxy: the raw atproto-proxy header value, or nil
  # query: raw query string (conn.query_string)
  # body: raw JSON string for POST, or nil
  # headers: conn.req_headers
  @type t :: %__MODULE__{}
end
