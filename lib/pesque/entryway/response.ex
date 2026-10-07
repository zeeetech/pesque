defmodule Pesque.Entryway.Response do
  @moduledoc """
  The upstream service's answer, buffered whole.

  The status line is kept as the upstream sent it, so a 404, 403 or 429 from
  the target reaches the client unchanged rather than being flattened into a
  failure of the proxy itself.
  """

  @enforce_keys [:status, :headers, :body]
  defstruct [:status, :headers, :body]

  # status: 100..599
  # headers: [{"content-type", "..."}] (strings)
  # body: binary
  @type t :: %__MODULE__{}
end
