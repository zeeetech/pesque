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
    post "/com.atproto.server.createAccount", SessionController, :create_account
    post "/com.atproto.server.createSession", SessionController, :create_session
    post "/com.atproto.server.refreshSession", SessionController, :refresh_session
    post "/com.atproto.server.deleteSession", SessionController, :delete_session
  end

  pipeline :auth do
    plug PesqueWeb.Plugs.Auth
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth

    get "/com.atproto.server.getSession", SessionController, :get_session
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.repo.getRecord", RepoController, :get_record
    get "/com.atproto.repo.listRecords", RepoController, :list_records
    get "/com.atproto.repo.describeRepo", RepoController, :describe_repo
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth

    post "/com.atproto.repo.createRecord", RepoController, :create_record
    post "/com.atproto.repo.putRecord", RepoController, :put_record
    post "/com.atproto.repo.deleteRecord", RepoController, :delete_record
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.sync.subscribeRepos", FirehoseController, :upgrade
    get "/com.atproto.sync.getRepo", SyncController, :get_repo
    get "/com.atproto.sync.getLatestCommit", SyncController, :get_latest_commit
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    match :*, "/*path", FallbackController, :not_implemented
  end
end
