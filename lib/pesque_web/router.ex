defmodule PesqueWeb.Router do
  use Phoenix.Router

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/_health", HealthController, :show
  end

  # Routes are compiled, mode is configured at boot, so a path_multi server
  # carries the conformant_single routes too and the controller decides.
  scope "/", PesqueWeb.Xrpc do
    get "/.well-known/did.json", IdentityController, :did_document
    get "/.well-known/atproto-did", IdentityController, :atproto_did
    get "/user/:username/did.json", IdentityController, :user_did_document
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.identity.resolveHandle", IdentityController, :resolve_handle
    get "/com.atproto.server.checkAccountStatus", SessionController, :check_account_status
  end

  # What the spec puts a limit on, and what it chose. Sessions are the ones a
  # stranger can reach without an account, so they get the tight number; reads
  # are what a feed polls, so they get the loose one.
  pipeline :session_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :session, limit: 100, window: 3_600_000
  end

  pipeline :read_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :read, limit: 3_000, window: 300_000
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :session_limits

    post "/com.atproto.server.createAccount", SessionController, :create_account
    post "/com.atproto.server.createSession", SessionController, :create_session
    post "/com.atproto.server.refreshSession", SessionController, :refresh_session
    post "/com.atproto.server.deleteSession", SessionController, :delete_session
  end

  # Every client asks this one first, so it answers without a rate limit of its
  # own and without a token: a client that cannot learn the server's DID cannot
  # get far enough to be worth limiting.
  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.server.describeServer", SessionController, :describe_server
  end

  pipeline :auth do
    plug PesqueWeb.Plugs.Auth
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth

    get "/com.atproto.server.getSession", SessionController, :get_session
    get "/com.atproto.server.getServiceAuth", SessionController, :get_service_auth
    post "/com.atproto.server.createInviteCodes", SessionController, :create_invite_codes
    post "/com.atproto.server.requestAccountDelete", SessionController, :request_account_delete
    post "/com.atproto.server.deleteAccount", SessionController, :delete_account
    post "/com.atproto.server.deactivateAccount", SessionController, :deactivate_account
    post "/com.atproto.server.activateAccount", SessionController, :activate_account
    post "/com.atproto.identity.updateHandle", IdentityController, :update_handle
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :read_limits

    get "/com.atproto.repo.getRecord", RepoController, :get_record
    get "/com.atproto.repo.listRecords", RepoController, :list_records
    get "/com.atproto.repo.describeRepo", RepoController, :describe_repo
    get "/com.atproto.sync.subscribeRepos", FirehoseController, :upgrade
    get "/com.atproto.sync.getRepo", SyncController, :get_repo
    get "/com.atproto.sync.getLatestCommit", SyncController, :get_latest_commit
    get "/com.atproto.sync.getBlob", SyncController, :get_blob
    get "/com.atproto.sync.getBlocks", SyncController, :get_blocks
    get "/com.atproto.sync.getRecord", SyncController, :get_record
    get "/com.atproto.sync.getRepoStatus", SyncController, :get_repo_status
    get "/com.atproto.sync.listRepos", SyncController, :list_repos
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth

    post "/com.atproto.repo.applyWrites", RepoController, :apply_writes
    post "/com.atproto.repo.createRecord", RepoController, :create_record
    post "/com.atproto.repo.putRecord", RepoController, :put_record
    post "/com.atproto.repo.deleteRecord", RepoController, :delete_record
    post "/com.atproto.repo.uploadBlob", RepoController, :upload_blob
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    match :*, "/*path", FallbackController, :not_implemented
  end
end
