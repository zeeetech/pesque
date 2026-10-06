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

  # The spec puts no limit on writes, so this number is ours and not a
  # protocol requirement: it is here because a write is the expensive request
  # on this server (MST rebuild, a signature, an fsync, and SQLite's single
  # writer lock held for the lot), so it is the one a client loop can turn into
  # a stall for everyone else. Two per second per account is well clear of what
  # a posting client does. Change it freely.
  #
  # It runs before the auth plug, like every other limit here, so a flood is
  # refused before it costs a token verification.
  pipeline :write_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :write, limit: 600, window: 300_000
  end

  # Minting invite codes is what decides who gets an account on a closed
  # server, so it is not an account-scoped call: it takes the server's own
  # identity, not any account's. Under :path_multi there is no server identity
  # and this refuses everyone including the operator, which is why that
  # topology needs an operator DID list before this is reachable.
  pipeline :admin do
    plug PesqueWeb.Plugs.Admin
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

  # What each authenticated route needs, which is what an OAuth token's scope
  # is checked against: read is the account's own session and service auth,
  # write is records and blobs, account is the endpoints that manage the
  # account itself and that transition:generic deliberately does not reach.
  # A legacy session token is one scope that grants all three, so nothing it
  # could reach before is behind a permission it does not have.
  pipeline :auth_read do
    plug PesqueWeb.Plugs.Auth, permission: :read
  end

  pipeline :auth_write do
    plug PesqueWeb.Plugs.Auth, permission: :write
  end

  pipeline :auth_account do
    plug PesqueWeb.Plugs.Auth, permission: :account
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth_read

    get "/com.atproto.server.getSession", SessionController, :get_session
    get "/com.atproto.server.getServiceAuth", SessionController, :get_service_auth
  end

  # Identity management is account permission, not the transition scope: an app
  # password can write records but cannot move the identity behind them. This
  # one also mints the account's rotation key on the first ask, so it is behind
  # the token rather than public.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth_account

    get "/com.atproto.identity.getRecommendedDidCredentials",
        IdentityController,
        :get_recommended_did_credentials
  end

  # listMissingBlobs walks every record of the account to find the blob refs,
  # so it is a read that costs like a repo listing rather than like a session
  # lookup, and it gets the read budget on top of the token.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:read_limits, :auth_read]

    get "/com.atproto.repo.listMissingBlobs", RepoController, :list_missing_blobs
  end

  # Account management is a write path like any other, and deleteAccount is the
  # expensive one: it verifies a password with argon2. The permit in Accounts
  # bounds how many of those run at once, which caps the memory but not the
  # rate, so without a limit of its own this scope has the cheapest 64 MiB a
  # token holder can spend, repeatedly and as fast as the network allows.
  #
  # The window matches :write_limits so the two write scopes read as one policy,
  # and it runs before the auth plug so a flood is refused before it costs a
  # token verification.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_account]

    post "/com.atproto.server.requestAccountDelete", SessionController, :request_account_delete
    post "/com.atproto.server.deleteAccount", SessionController, :delete_account
    post "/com.atproto.server.deactivateAccount", SessionController, :deactivate_account
    post "/com.atproto.server.activateAccount", SessionController, :activate_account
    post "/com.atproto.identity.updateHandle", IdentityController, :update_handle
    post "/com.atproto.identity.submitPlcOperation", IdentityController, :submit_plc_operation
  end

  # Behind :admin as well as :auth_account, because on this server it is also
  # the operator's endpoint rather than an account's.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_account, :admin]

    post "/com.atproto.server.createInviteCodes", SessionController, :create_invite_codes
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
    get "/com.atproto.sync.listBlobs", SyncController, :list_blobs
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_write]

    post "/com.atproto.repo.applyWrites", RepoController, :apply_writes
    post "/com.atproto.repo.createRecord", RepoController, :create_record
    post "/com.atproto.repo.putRecord", RepoController, :put_record
    post "/com.atproto.repo.deleteRecord", RepoController, :delete_record
    post "/com.atproto.repo.uploadBlob", RepoController, :upload_blob
    post "/com.atproto.repo.importRepo", RepoController, :import_repo
  end

  # OAuth. The metadata documents come first and are answered without a rate
  # limit for the same reason describeServer is: a client that cannot learn
  # where the authorization server is cannot get far enough to be worth
  # limiting.
  #
  # The rest get their own bucket rather than sharing :session. A sign-in is
  # several OAuth requests on top of the session request it replaces, so a
  # shared budget would let one login attempt spend the allowance the session
  # endpoints were given, and the two limits would stop meaning what their
  # numbers say.
  scope "/", PesqueWeb.OAuth do
    get "/.well-known/oauth-authorization-server", MetadataController, :authorization_server
    get "/.well-known/oauth-protected-resource", MetadataController, :protected_resource
    get "/oauth/jwks.json", MetadataController, :jwks
  end

  pipeline :oauth_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :oauth, limit: 100, window: 3_600_000
  end

  scope "/oauth", PesqueWeb.OAuth do
    pipe_through :oauth_limits

    post "/par", AuthorizationController, :par
    get "/authorize", AuthorizationController, :authorize
    post "/authorize", AuthorizationController, :decide
    post "/token", TokenController, :token
    post "/revoke", TokenController, :revoke
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    match :*, "/*path", FallbackController, :not_implemented
  end
end
