defmodule PesqueWeb.OAuth.MetadataController do
  @moduledoc """
  The three documents a client fetches before it does anything else.

  `/.well-known/oauth-authorization-server` is what the client checks the whole
  profile against: PAR required, S256 only, DPoP ES256, private_key_jwt
  available. `/.well-known/oauth-protected-resource` is what a client that
  started from a PDS hostname rather than an account identifier reads to find
  the authorization server, and it points back here. `/oauth/jwks.json` is the
  key an access token is verified with.

  All three are JSON, 200, and reachable without a token: a client that cannot
  learn the server's metadata cannot get far enough to be worth authenticating.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.OAuth
  alias Pesque.OAuth.Keys

  def authorization_server(conn, _params), do: json(conn, OAuth.metadata())

  def protected_resource(conn, _params), do: json(conn, OAuth.resource_metadata())

  def jwks(conn, _params), do: json(conn, Keys.jwks())
end
