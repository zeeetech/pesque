defmodule PesqueWeb.Router do
  use Phoenix.Router

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/_health", HealthController, :show
  end

  scope "/", PesqueWeb.Xrpc do
    get "/.well-known/did.json", IdentityController, :did_document
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.identity.resolveHandle", IdentityController, :resolve_handle
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    match :*, "/*path", FallbackController, :not_implemented
  end
end
