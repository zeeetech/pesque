defmodule PesqueWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pesque

  plug Plug.RequestId
  # The stop half of this pair is what Pesque.Metrics counts requests from.
  # log: false because Phoenix.Logger also listens on this event and Plug.Logger
  # below is already the request log; without it every request would be logged twice.
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: false
  plug Plug.Logger
  plug PesqueWeb.Plugs.SecurityHeaders
  plug PesqueWeb.Plugs.Cors

  plug Plug.Static,
    at: "/",
    from: :pesque,
    only: ~w(privacy-policy.md terms-of-service.md)

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: JSON,
    length: 8_000_000

  plug PesqueWeb.Router
end
