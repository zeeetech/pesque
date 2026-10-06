defmodule Pesque.Repo.Migrations.CreateOauth do
  use Ecto.Migration

  # The atproto OAuth profile is a four-part flow and three of the four parts
  # are server-side state a signed token cannot carry on its own: a pushed
  # authorization request has to survive the redirect to the login page, a code
  # has to be single use, and a refresh token has to be rotatable and
  # revocable. So the requests, the tokens and the DPoP nonce are rows.
  #
  # Nothing here is stored in the clear. A request_uri, a code and a refresh
  # token are all bearer credentials, so each is kept as the SHA-256 of the
  # value and looked up by that hash, the way a refresh jti and a deletion
  # token already are. A row lifted out of this table must not be enough to
  # finish somebody else's flow.
  def change do
    create table(:oauth_requests) do
      add :request_uri_hash, :text, null: false
      add :client_id, :text, null: false
      add :redirect_uri, :text, null: false
      add :state, :text, null: false
      add :scope, :text, null: false
      add :code_challenge, :text, null: false
      add :code_challenge_method, :text, null: false
      add :login_hint, :text
      add :dpop_jkt, :text, null: false
      add :did, :text
      add :code_hash, :text
      add :code_expires_at, :utc_datetime
      add :used_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_requests, [:request_uri_hash])
    create unique_index(:oauth_requests, [:code_hash])

    create table(:oauth_tokens) do
      add :token_hash, :text, null: false
      add :jti, :text, null: false
      add :kind, :text, null: false
      add :did, :text, null: false
      add :client_id, :text, null: false
      add :scope, :text, null: false
      add :dpop_jkt, :text, null: false
      add :session_id, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_tokens, [:token_hash])
    create unique_index(:oauth_tokens, [:jti])
    create index(:oauth_tokens, [:session_id])
    create index(:oauth_tokens, [:did])

    # One live nonce for the whole server, which the spec allows: it exists to
    # bind a proof to this server, not to a session. Rotating it replaces the
    # row rather than adding one, and the row it replaces is kept in `previous`
    # so a request already in flight with the old nonce still verifies.
    create table(:oauth_dpop_nonces) do
      add :nonce, :text, null: false
      add :previous, :text
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_dpop_nonces, [:nonce])
  end
end