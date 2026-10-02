defmodule PesqueWeb.Router do
  use Phoenix.Router

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/_health", HealthController, :show
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    match :*, "/*path", FallbackController, :not_implemented
  end
end
