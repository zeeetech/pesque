defmodule PesqueWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :pesque

  plug Plug.RequestId
  plug Plug.Logger
  plug PesqueWeb.Plugs.SecurityHeaders
  plug PesqueWeb.Plugs.Cors

  plug Plug.Static,
    at: "/",
    from: :pesque,
    only: ~w(privacy-policy.md terms-of-service.md assets)

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: JSON,
    length: 8_000_000

  # The locale is a request-scoped concern, resolved once here so an error page
  # Phoenix renders after the router fails reads in the same language as the
  # page that would have answered. It reads the query and the cookies, so it
  # runs after the parsers.
  plug PesqueWeb.Plugs.SetLocale

  plug PesqueWeb.Router
end
