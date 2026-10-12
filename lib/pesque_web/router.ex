defmodule PesqueWeb.Router do
  use Phoenix.Router

  scope "/xrpc", PesqueWeb.Xrpc do
    get "/_health", HealthController, :show
  end

  # Caddy's on-demand TLS consults this before issuing any certificate under
  # the wildcard, so it has to be public and cheap: a name is allowed because
  # an account row says so, which is the same fact resolveHandle already
  # publishes, and the read budget is the whole cost of one indexed lookup.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :read_limits

    get "/_tls-check", TlsCheckController, :show
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

  # The spec puts no limit on writes, so this number is ours: a write is the
  # expensive request on this server (MST rebuild, a signature, an fsync, and
  # SQLite's single writer lock held for the lot), the one a client loop can
  # turn into a stall for everyone else. It runs before the auth plug, like
  # every other limit here, so a flood is refused before it costs a token
  # verification.
  pipeline :write_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :write, limit: 600, window: 300_000
  end

  # A proxied call is a read the entryway makes on the account's behalf, so it
  # gets the read budget. It runs before the auth plug like every other limit.
  pipeline :proxy_limits do
    plug PesqueWeb.Plugs.RateLimit, bucket: :proxy, limit: 3_000, window: 300_000
  end

  # Minting invite codes is what decides who gets an account on a closed
  # server, so it is not an account-scoped call: it takes the server's own
  # identity, not any account's. Under :path_multi there is no server identity
  # and this refuses everyone including the operator, so that topology needs
  # an operator DID list before this is reachable.
  pipeline :admin do
    plug PesqueWeb.Plugs.Admin
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :session_limits

    post "/com.atproto.server.createAccount", SessionController, :create_account
    post "/com.atproto.server.createSession", SessionController, :create_session
    post "/com.atproto.server.refreshSession", SessionController, :refresh_session
    post "/com.atproto.server.deleteSession", SessionController, :delete_session

    # The password reset flow is the one session endpoint a caller reaches
    # without a credential at all, so it takes the tight, unauthenticated
    # budget alongside the session verbs it belongs with. requestPasswordReset
    # is a no-op against an unknown address; resetPassword spends a code the
    # request logged.
    post "/com.atproto.server.requestPasswordReset", SessionController, :request_password_reset
    post "/com.atproto.server.resetPassword", SessionController, :reset_password
  end

  # Every client asks this one first, so it answers without a rate limit of its
  # own and without a token: a client that cannot learn the server's DID cannot
  # get far enough to be worth limiting.
  scope "/xrpc", PesqueWeb.Xrpc do
    get "/com.atproto.server.describeServer", SessionController, :describe_server
  end

  # What each authenticated route needs, matched against an OAuth token's
  # grants by the auth plug. One pipeline per requirement, verbose on purpose:
  # a route says what it needs to reach, and the requirement is grep-able from
  # here. A legacy session token carries its tier in the scope claim, and the
  # plug computes the grants from it.
  pipeline :auth_session do
    plug PesqueWeb.Plugs.Auth, require: :session
  end

  pipeline :auth_repo_create do
    plug PesqueWeb.Plugs.Auth, require: {:repo, :create}
  end

  pipeline :auth_repo_upsert do
    plug PesqueWeb.Plugs.Auth, require: {:repo, :upsert}
  end

  pipeline :auth_repo_delete do
    plug PesqueWeb.Plugs.Auth, require: {:repo, :delete}
  end

  pipeline :auth_repo_apply do
    plug PesqueWeb.Plugs.Auth, require: {:repo, :apply}
  end

  pipeline :auth_blob do
    plug PesqueWeb.Plugs.Auth, require: :blob
  end

  pipeline :auth_import_repo do
    plug PesqueWeb.Plugs.Auth, require: :import_repo
  end

  pipeline :auth_service_auth do
    plug PesqueWeb.Plugs.Auth, require: :service_auth
  end

  pipeline :auth_proxy do
    plug PesqueWeb.Plugs.Auth, require: :proxy
  end

  pipeline :auth_preferences_get do
    plug PesqueWeb.Plugs.Auth, require: {:preferences, :get}
  end

  pipeline :auth_preferences_put do
    plug PesqueWeb.Plugs.Auth, require: {:preferences, :put}
  end

  pipeline :auth_identity_handle do
    plug PesqueWeb.Plugs.Auth, require: {:identity, :handle}
  end

  pipeline :auth_identity_all do
    plug PesqueWeb.Plugs.Auth, require: {:identity, :all}
  end

  pipeline :auth_account_management do
    plug PesqueWeb.Plugs.Auth, require: :account_management
  end

  pipeline :auth_full_session do
    plug PesqueWeb.Plugs.Auth, require: :full_session
  end

  pipeline :auth_app_password_management do
    plug PesqueWeb.Plugs.Auth, require: :app_password_management
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth_session

    get "/com.atproto.server.getSession", SessionController, :get_session

    # Confirming an email is about the caller's own account, so a valid session
    # is the whole requirement: the code requestEmailConfirmation logs is bound
    # to the account's address, and confirmEmail only spends it.
    post "/com.atproto.server.requestEmailConfirmation",
         SessionController,
         :request_email_confirmation

    post "/com.atproto.server.confirmEmail", SessionController, :confirm_email

    # A confirmed address takes a code to move; an unconfirmed one does not.
    # Both endpoints stay behind a valid session, like the confirmation pair.
    post "/com.atproto.server.requestEmailUpdate", SessionController, :request_email_update
    post "/com.atproto.server.updateEmail", SessionController, :update_email
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth_service_auth

    get "/com.atproto.server.getServiceAuth", SessionController, :get_service_auth
  end

  # Identity management is identity permission, not the transition scope: an
  # app password can write records but cannot move the identity behind them.
  # This one also mints the account's rotation key on the first ask, so it is
  # behind the token rather than public.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through :auth_identity_handle

    get "/com.atproto.identity.getRecommendedDidCredentials",
        IdentityController,
        :get_recommended_did_credentials
  end

  # listMissingBlobs walks every record of the account to find the blob refs,
  # so it is a read that costs like a repo listing rather than like a session
  # lookup, and it gets the read budget on top of the token. What it answers
  # is public data, so any valid token reaches it.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:read_limits, :auth_session]

    get "/com.atproto.repo.listMissingBlobs", RepoController, :list_missing_blobs
  end

  # Account management is a write path like any other, and deleteAccount is the
  # expensive one: it verifies a password with argon2. The permit in Accounts
  # caps the memory, not the rate, so without a limit of its own this scope is
  # the cheapest 64 MiB a token holder can spend. The window matches
  # :write_limits so the two write scopes read as one policy.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_account_management]

    post "/com.atproto.server.requestAccountDelete", SessionController, :request_account_delete
    post "/com.atproto.server.deleteAccount", SessionController, :delete_account
    post "/com.atproto.server.deactivateAccount", SessionController, :deactivate_account
    post "/com.atproto.server.activateAccount", SessionController, :activate_account
  end

  # The handle is the one identity attribute a granular client can ask for;
  # the operations below can change keys and services, which is the whole
  # identity and nothing narrower.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_identity_handle]

    post "/com.atproto.identity.updateHandle", IdentityController, :update_handle
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_identity_all]

    post "/com.atproto.identity.submitPlcOperation", IdentityController, :submit_plc_operation

    # The moving-out half of the same story: this server holds the rotation
    # key, so it is the one that signs the operation carrying the account's
    # next credentials, gated on the code request above hands out. Signing or
    # submitting an operation can change keys and services, not just the
    # handle, so both take the whole identity and nothing narrower.
    post "/com.atproto.identity.requestPlcOperationSignature",
         IdentityController,
         :request_plc_operation_signature

    post "/com.atproto.identity.signPlcOperation", IdentityController, :sign_plc_operation
  end

  # Behind :admin as well as :auth_account_management, because on this server
  # it is also the operator's endpoint rather than an account's.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_account_management, :admin]

    post "/com.atproto.server.createInviteCodes", SessionController, :create_invite_codes
  end

  # App passwords. Creating one takes the account password itself (:full_session),
  # because a credential that outlives the session that made it is the one thing
  # no permission in the grammar names; listing and revoking are management, so a
  # privileged app password reaches them and a plain one does not. OAuth tokens
  # are refused on all three: an OAuth session is managed in the OAuth surface,
  # not here.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_full_session]

    post "/com.atproto.server.createAppPassword", SessionController, :create_app_password
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:read_limits, :auth_app_password_management]

    get "/com.atproto.server.listAppPasswords", SessionController, :list_app_passwords
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_app_password_management]

    post "/com.atproto.server.revokeAppPassword", SessionController, :revoke_app_password
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
    pipe_through [:write_limits, :auth_repo_apply]

    post "/com.atproto.repo.applyWrites", RepoController, :apply_writes
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_repo_create]

    post "/com.atproto.repo.createRecord", RepoController, :create_record
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_repo_upsert]

    post "/com.atproto.repo.putRecord", RepoController, :put_record
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_repo_delete]

    post "/com.atproto.repo.deleteRecord", RepoController, :delete_record
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_blob]

    post "/com.atproto.repo.uploadBlob", RepoController, :upload_blob
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_import_repo]

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

  # Preferences are local: the PDS owns the account's private document, and an
  # atproto-proxy header on either method is ignored. getPreferences unblocks
  # the official app at login.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:read_limits, :auth_preferences_get]

    get "/app.bsky.actor.getPreferences", PreferencesController, :get_preferences
  end

  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:write_limits, :auth_preferences_put]

    post "/app.bsky.actor.putPreferences", PreferencesController, :put_preferences
  end

  # Everything else: a method this server does not implement. A call naming a
  # target with atproto-proxy is forwarded to it; a call naming none is 501.
  # This runs behind auth, so an unauthenticated unknown method answers 401 and
  # an authenticated one with no header answers 501. It must stay last.
  scope "/xrpc", PesqueWeb.Xrpc do
    pipe_through [:proxy_limits, :auth_proxy]

    match :*, "/*path", ProxyController, :forward
  end
end
