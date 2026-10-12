defmodule PesqueWeb.Plugs.Auth do
  @moduledoc """
  Requires a valid access token for an account this server hosts, and narrows
  an OAuth token to the permissions it was actually granted.

  Two kinds of token are accepted and both end up in the same three assigns,
  so nothing downstream knows which one arrived:

    * an OAuth access token, ES256 over the key published in the JWKS, bound
      to a DPoP key, and gated on the grants its scope string computes to
    * a legacy session token, HS256 over this server's secret, carrying its
      tier in the scope claim (the account password's full access, or one of
      the two app-password tiers), and gated on the grants that claim
      computes to

  Which is which is decided by the `alg` in the token's own header rather than
  by trying one verifier and falling back to the other. A fallback would mean
  a token that failed the OAuth check gets a second chance against the legacy
  one, and the answer to "which verification failed" would stop being
  meaningful. It also means nothing is ever verified as a kind it did not
  claim: an `alg` this server does not issue is refused outright.

  An OAuth token is only usable with a DPoP proof over this very request, from
  the key the session was minted for. That is checked after the token verifies
  and never skipped: a request carrying an OAuth token without a proof is
  refused rather than served, and the refusal is one a client can act on,
  because a proof that needs the server nonce comes back as `use_dpop_nonce`
  with the nonce in `DPoP-Nonce`.

  What an OAuth token may do is decided per route. Each route names a
  requirement through the `require:` option, and the plug builds the concrete
  permission that requirement asks for out of the request's own facts (the
  collection parameter, the write's action, the lxm and audience, the content
  type). The plug answers 403 only when those facts are present and
  well-formed; when they are missing or malformed it steps aside, because the
  controller's own validation is already about to answer 400, 401 or 415 and
  no permission check belongs ahead of a request that will not reach an
  action.

  The account is looked up, not inferred from the token's subject. A validly
  signed token for an account this server does not host has no one behind it,
  so it is rejected the same way a bad signature is.

  The reason is logged because a stranger scanning, a client with a wrong
  clock and a user whose session broke all look identical from outside, and
  only the first two are worth knowing about. No token, proof or assertion is
  ever logged.
  """

  import Plug.Conn

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.Entryway.Proxy
  alias Pesque.OAuth
  alias Pesque.OAuth.Grants
  alias Pesque.OAuth.Jwt
  alias Pesque.OAuth.Permission
  alias Pesque.Secret
  alias Pesque.Token
  alias PesqueWeb.OAuth.Proof
  alias PesqueWeb.Xrpc
  alias PesqueWeb.Xrpc.Errors

  require Logger

  # The scopes a legacy session token can carry: the account password's full
  # access, and the two app-password tiers. The tier travels in the claim,
  # the way an OAuth token's scopes do, so one verify path covers all three.
  @access_scopes ["com.atproto.access", "com.atproto.appPass", "com.atproto.appPassPrivileged"]

  # The shapes a request fact must have before this plug is willing to answer
  # 403 on it. A fact that is absent or malformed is the controller's 400 to
  # answer, so these mirror the regexes the domain already enforces rather
  # than inventing stricter ones.
  @nsid_regex ~r/\A[a-zA-Z][a-zA-Z0-9\-]*(\.[a-zA-Z][a-zA-Z0-9\-]*){2,}\z/

  # The same shape Pesque.ServiceAuth checks audiences against, fragment
  # optional: getServiceAuth mints tokens for bare DIDs too.
  @aud_regex ~r/\Adid:(web|plc):[a-zA-Z0-9._%\-]+(:[a-zA-Z0-9._\-]+)*(#[a-zA-Z0-9._\-]+)?\z/
  @aud_max_length 2048

  @write_actions %{
    "com.atproto.repo.applyWrites#create" => :create,
    "com.atproto.repo.applyWrites#update" => :update,
    "com.atproto.repo.applyWrites#delete" => :delete
  }

  # A route that names no requirement is a bug, not a default, so it is a
  # compile error: the router evaluates init/1 while compiling pipelines.
  def init(opts) do
    case Keyword.fetch(opts, :require) do
      {:ok, require} ->
        require

      :error ->
        raise ArgumentError,
              "PesqueWeb.Plugs.Auth needs a :require option naming what the route asks for"
    end
  end

  def call(conn, require) do
    case authenticate(conn, require) do
      {:ok, conn, user} ->
        conn
        |> assign(:did, user.did)
        |> assign(:current_user, user)

      {:error, reason, failed} ->
        Logger.warning("rejected request: #{describe(reason)}", route: conn.request_path)

        refuse(failed, reason)
    end
  end

  # Every arm answers {:ok, conn, user} or {:error, reason, conn}, so the caller
  # has one shape to handle and the failed conn is the one carrying whatever
  # the proof check put on it, such as the nonce a client has to retry with.
  defp authenticate(conn, require) do
    with {:ok, token} <- bearer(conn),
         {:ok, kind, claims} <- verify(token),
         {:ok, conn} <- prove(conn, kind, token, claims),
         {:ok, grants} <- authorize(kind, claims, require, conn),
         {:ok, user} <- account(claims) do
      {:ok, assign(conn, :grants, grants), user}
    else
      {:error, reason, failed} -> {:error, reason, failed}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  # A token arriving without the prefix is not a token this server issues in
  # either scheme, so it is refused here rather than parsed twice.
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["DPoP " <> token] when token != "" -> {:ok, token}
      [_ | _] -> {:error, :malformed_authorization}
      [] -> {:error, :no_bearer_token}
    end
  end

  # The two verifiers answer :invalid_token, which on the XRPC surface means
  # something narrower (a token for another account), so the reason is renamed
  # here rather than translated in two places downstream. A signature that did
  # not verify, an expired token, a revoked one and a tampered header are all
  # the same answer to the client and one reason here.
  defp verify(token) do
    case Jwt.alg(token) do
      {:ok, "ES256"} -> oauth(token)
      {:ok, "HS256"} -> session(token)
      _other -> {:error, :rejected_token}
    end
  end

  defp oauth(token) do
    case OAuth.verify_access_token(token) do
      {:ok, claims} -> {:ok, :oauth, claims}
      {:error, _reason} -> {:error, :rejected_token}
    end
  end

  defp session(token) do
    case Token.verify(token, Secret.get(), @access_scopes) do
      {:ok, claims} -> {:ok, :session, claims}
      {:error, _reason} -> {:error, :rejected_token}
    end
  end

  # A legacy session token carries no proof and needs none: it is HS256 over a
  # secret only this server holds, and the bearer of it is whoever holds it.
  # The OAuth path has to show the key instead, which is what DPoP is for.
  defp prove(conn, :session, _token, _claims), do: {:ok, conn}

  defp prove(conn, :oauth, token, claims) do
    case Proof.check(conn, token) do
      {:ok, checked} ->
        if secure_equal?(checked.assigns.dpop_jkt, OAuth.jkt(claims)) do
          {:ok, Proof.with_nonce(checked)}
        else
          {:error, :dpop_key_mismatch, conn}
        end

      {:error, reason, failed} ->
        {:error, reason, failed}
    end
  end

  # The thumbprint is not a secret, but comparing it in constant time costs
  # nothing and means nothing about this path depends on how the strings
  # happened to be laid out in memory.
  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  # App password management is a legacy-session surface, so it is answered by
  # the credential kind before any grant is computed: an OAuth token is refused
  # however broad its grants, because minting credentials that outlive the
  # session that made them is the one escalation no permission in the grammar
  # names, and a privileged app password is refused on create because creating
  # credentials is what the account password is for.
  defp authorize(:session, %{"scope" => "com.atproto.access"} = claims, :full_session, _conn),
    do: {:ok, Grants.from_session_scope(claims["scope"])}

  defp authorize(:session, _claims, :full_session, _conn),
    do: {:error, {:insufficient_scope, "app passwords are created with the account password"}}

  defp authorize(:session, claims, :app_password_management, _conn) do
    grants = Grants.from_session_scope(claims["scope"])

    if account_management?(grants) do
      {:ok, grants}
    else
      {:error, {:insufficient_scope, "app password management (a privileged credential)"}}
    end
  end

  defp authorize(:session, claims, require, conn) do
    grants = Grants.from_session_scope(claims["scope"])

    case satisfied?(grants, require, conn) do
      :ok -> {:ok, grants}
      {:error, _reason} = error -> error
    end
  end

  defp authorize(:oauth, _claims, :full_session, _conn),
    do: {:error, {:insufficient_scope, "OAuth tokens do not manage app passwords"}}

  defp authorize(:oauth, _claims, :app_password_management, _conn),
    do: {:error, {:insufficient_scope, "OAuth tokens do not manage app passwords"}}

  defp authorize(:oauth, claims, require, conn) do
    grants = grants_from(claims)

    case satisfied?(grants, require, conn) do
      :ok -> {:ok, grants}
      {:error, _reason} = error -> error
    end
  end

  # An access token minted by this build carries the grant string its issuance
  # expanded and stored, which is the permissions it was actually given: that
  # expansion is fixed for the token's life and an include in the scope string
  # has already been replaced by it. Older rows carry no grants column value,
  # and their grants are computed from the scope, as they always were.
  defp grants_from(%{"grants" => grants}) when is_binary(grants), do: Grants.parse(grants)
  defp grants_from(claims), do: Grants.parse(Map.get(claims, "scope", ""))

  # The requirement that is only a valid token, for either kind: what the
  # route reveals beyond the account's identity is the controller's to gate.
  defp satisfied?(_grants, :session, _conn), do: :ok

  # The two requirements that are not one permission, answered against the
  # grants directly, each with the string the 403 names.
  defp satisfied?(grants, :account_management, _conn) do
    if account_management?(grants),
      do: :ok,
      else: {:error, {:insufficient_scope, "account management (the atproto scope)"}}
  end

  defp satisfied?(grants, {:preferences, verb}, _conn) do
    if Grants.preferences?(grants, verb),
      do: :ok,
      else: {:error, {:insufficient_scope, preference_display(verb)}}
  end

  defp satisfied?(grants, require, conn) do
    case build_required(require, conn) do
      {:ok, required} ->
        case Enum.find(required, &(not Grants.permits?(grants, &1))) do
          nil -> :ok
          missing -> {:error, {:insufficient_scope, Permission.serialize(missing)}}
        end

      # The facts are missing or malformed: the controller's own validation
      # answers this request, and it is the answer the client already had.
      :unbuildable ->
        :ok
    end
  end

  # Account management has no granular permission today: the permission spec
  # defines no account attribute for hosting status. The tier is therefore
  # reachable only by the atproto full grant. When the spec grows an
  # attribute, this becomes one covers? clause and the router tags change.
  defp account_management?(grants), do: Enum.any?(grants, &(&1.resource == :atproto))

  defp preference_display(:get), do: "rpc:app.bsky.actor.getPreferences"
  defp preference_display(:put), do: "rpc:app.bsky.actor.putPreferences"

  # The concrete permission a requirement names, built from the request's own
  # facts. Every arm answers {:ok, [required]} or :unbuildable; a requirement
  # naming several facts requires all of them.
  defp build_required({:repo, :create}, conn), do: repo_required(conn, [:create])
  defp build_required({:repo, :upsert}, conn), do: repo_required(conn, [:create, :update])
  defp build_required({:repo, :delete}, conn), do: repo_required(conn, [:delete])

  defp build_required({:repo, :apply}, conn), do: apply_requirements(conn.params["writes"])

  defp build_required(:blob, conn) do
    case Blob.request_media_type(conn.req_headers) do
      {:ok, media_type} -> {:ok, [Permission.blob_required(media_type)]}
      {:error, :not_a_blob_body} -> :unbuildable
    end
  end

  defp build_required(:import_repo, _conn),
    do: {:ok, [Permission.account_required(:repo, :manage)]}

  defp build_required(:service_auth, conn) do
    aud = conn.params["aud"]
    lxm = conn.params["lxm"]

    cond do
      not aud_ref?(aud) ->
        :unbuildable

      is_binary(lxm) and valid_nsid?(lxm) ->
        {:ok, [Permission.rpc_required(lxm, aud)]}

      is_nil(lxm) ->
        {:ok, [Permission.rpc_required(:any, aud)]}

      true ->
        :unbuildable
    end
  end

  defp build_required(:proxy, conn) do
    nsid = String.replace_prefix(conn.request_path, "/xrpc/", "")
    proxy = List.first(get_req_header(conn, "atproto-proxy"))

    with {:ok, target} <- Proxy.parse_header(proxy),
         true <- valid_nsid?(nsid) do
      {:ok, [Permission.rpc_required(nsid, target.did <> "#" <> target.service_id)]}
    else
      # No header is the 501 the catch-all answers; a malformed one is its
      # 400. Both are the controller's to answer, not this plug's.
      _error -> :unbuildable
    end
  end

  defp build_required({:identity, :handle}, _conn),
    do: {:ok, [Permission.identity_required(:handle)]}

  defp build_required({:identity, :all}, _conn),
    do: {:ok, [Permission.identity_required(:*)]}

  defp repo_required(conn, actions) do
    if valid_nsid?(conn.params["collection"]) do
      {:ok, [Permission.repo_required(conn.params["collection"], actions)]}
    else
      :unbuildable
    end
  end

  # applyWrites is atomic, so every write's permission is required, not any
  # one of them. A writes value that is not a list of shaped writes is the
  # controller's 400 to answer.
  defp apply_requirements(writes) when is_list(writes) do
    Enum.reduce_while(writes, {:ok, []}, fn write, {:ok, acc} ->
      case write_requirement(write) do
        {:ok, permission} -> {:cont, {:ok, [permission | acc]}}
        :error -> {:halt, :unbuildable}
      end
    end)
    |> case do
      {:ok, required} -> {:ok, Enum.reverse(required)}
      :unbuildable -> :unbuildable
    end
  end

  defp apply_requirements(_writes), do: :unbuildable

  defp write_requirement(%{"collection" => collection, "$type" => type})
       when is_binary(collection) and is_binary(type) do
    one = Map.get(@write_actions, type)

    if one != nil and valid_nsid?(collection) do
      {:ok, Permission.repo_required(collection, [one])}
    else
      :error
    end
  end

  defp write_requirement(_write), do: :error

  defp valid_nsid?(nsid) when is_binary(nsid), do: Regex.match?(@nsid_regex, nsid)
  defp valid_nsid?(_nsid), do: false

  defp aud_ref?(aud) when is_binary(aud),
    do: byte_size(aud) <= @aud_max_length and Regex.match?(@aud_regex, aud)

  defp aud_ref?(_aud), do: false

  defp account(claims) do
    case Accounts.get_user(claims["sub"]) do
      %User{} = user -> {:ok, user}
      _other -> {:error, :unknown_account}
    end
  end

  # The refusal is an XRPC error the way every other one here is, plus the
  # header the OAuth profile requires on an authenticated request. A client
  # that reads only the header still learns which of the two things to fix:
  # the token or the proof.
  defp refuse(conn, reason) do
    conn
    |> put_resp_header("www-authenticate", Errors.to_challenge(reason))
    |> Xrpc.error(reason)
  end

  defp describe(:no_bearer_token), do: "no bearer token"
  defp describe(:malformed_authorization), do: "malformed authorization header"
  defp describe(:rejected_token), do: "token did not verify"
  defp describe(:unknown_account), do: "token named an account this server does not host"
  defp describe({:insufficient_scope, permission}), do: "token lacks #{permission}"
  defp describe(:use_dpop_nonce), do: "proof needs the server nonce"

  defp describe(reason) when reason in [:missing_dpop_proof, :dpop_key_mismatch],
    do: "dpop proof rejected"

  defp describe(_reason), do: "dpop proof did not verify"
end
