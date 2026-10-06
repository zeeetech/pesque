defmodule PesqueWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pesque

  plug Plug.RequestId
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
