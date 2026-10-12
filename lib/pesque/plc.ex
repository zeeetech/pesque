defmodule Pesque.Plc do
  @moduledoc """
  did:plc account minting and updates against the PLC directory.

  Opt-in through `PDS_IDENTITY=plc`. Under the default `PDS_IDENTITY=web`
  nothing here runs: accounts are did:web, `Pesque.Accounts` never calls into
  this module, and every code path below is dead.

  A freshly minted account is registered with the directory before its row is
  written. If the submission fails nothing is persisted: the caller gets an
  error, the key files are removed, and no account exists. A row whose DID does
  not resolve would make `checkAccountStatus` and `getRepoStatus` lie about an
  account nobody can reach, so there is no half-created state to recover from.
  The cost of that choice is the opposite edge: a createAccount that loses a
  handle race after its operation was accepted leaves an orphan DID at the
  directory. It resolves to a document naming this server, but no row here
  serves it. That is a smaller lie than a row that resolves to nothing, and the
  handle unique index still admits exactly one account.

  A hosted did:plc account moves out through two endpoints this module
  answers: `request_operation_signature/1` issues the code the spec emails,
  and `sign_operation/2` spends it on a signed operation built over the
  stored one. Neither talks to the directory: the signature is the product,
  and a submitted operation is `submit_operation/2`'s business.

  The rotation key is the account's only recovery path and is not recoverable
  from the operation log; see `Pesque.Plc.Keys`.
  """

  alias Pesque.Accounts.User
  alias Pesque.Did
  alias Pesque.Plc.Directory
  alias Pesque.Plc.Keys
  alias Pesque.Plc.Operation
  alias Pesque.Plc.Token
  alias Pesque.Repo
  alias Pesque.Secp256k1

  import Ecto.Query

  require Logger

  # The reference PDS gives its emailed code 15 minutes. An operator reading
  # one out of a log or a CLI hands it over in less, and a short life is the
  # point: the code authorizes moving the identity.
  @plc_token_ttl_seconds 15 * 60

  # The fields a signPlcOperation request may replace wholesale. Everything
  # else the operation carries - type, prev, sig - is not a client's to name.
  @plc_fields ["rotationKeys", "alsoKnownAs", "verificationMethods", "services"]

  @doc "Whether accounts are minted as did:plc."
  def enabled?, do: Pesque.identity() == :plc

  @doc """
  Mints a did:plc identity for a handle: repo and rotation keys, a signed
  genesis operation, and the DID the directory registered.

  Answers `{:ok, %{did:, key:, operation:}}`, where `operation` is the signed
  operation as JSON for the account row. On any failure the key files are
  removed, so a failed mint leaves nothing behind and the caller writes no row.
  """
  def mint(handle) do
    {repo_pub, repo_priv} = Secp256k1.generate_keypair()
    {rotation_pub, rotation_priv} = Secp256k1.generate_keypair()

    attrs = %{
      signing_key: Did.key_did(repo_pub),
      rotation_keys: [Did.key_did(rotation_pub)],
      handle: handle,
      pds: Pesque.service_endpoint()
    }

    {op, did} = Operation.genesis(attrs, rotation_priv)

    with {:ok, key} <- claim_keys(did, repo_pub, repo_priv, rotation_pub, rotation_priv),
         :ok <- submit(did, op) do
      {:ok, %{did: did, key: key, operation: JSON.encode!(op)}}
    else
      {:error, reason} ->
        Keys.delete(did)
        {:error, reason}
    end
  end

  @doc """
  Writes a handle change to a did:plc account's operation log.

  Answers `{:ok, operation_json}` or `{:error, reason}`. The caller updates its
  row only after this succeeds: a handle this server resolves but the DID
  document does not claim would resolve to nothing for everyone else.
  """
  def update_handle(%User{did: did, plc_operation: stored}, handle) do
    with {:ok, prev} <- decode_operation(stored),
         {:ok, rotation_priv} <- load_rotation(did),
         op = Operation.update(prev, %{"alsoKnownAs" => ["at://" <> handle]}, rotation_priv),
         :ok <- submit(did, op) do
      {:ok, JSON.encode!(op)}
    end
  end

  @doc """
  Verifies a did:plc account's document points at this server's PDS endpoint.

  Answers :ok, or `{:error, :pds_mismatch}` when the document names another
  server, or `{:error, :plc_unreachable}` when the directory cannot be reached.
  A did:web account needs no such check: its document is served here and
  derived from this server's own hostname.
  """
  def verify_pds(did) do
    with {:ok, document} <- client().resolve(did),
         {:ok, endpoint} <- pds_endpoint(document) do
      if endpoint == Pesque.service_endpoint() do
        :ok
      else
        {:error, :pds_mismatch}
      end
    end
  end

  @doc """
  The DID credentials this server recommends for a migrating account.

  The signing key is the one this server holds for the account, so the
  operation the old PDS signs points commits at a key the new host can use. A
  did:plc account also gets a rotation key, minted here on the first ask and
  kept in the key directory: without one this server cannot help manage or
  recover the identity after the move. A did:web account has no operation log
  and no rotation key, so the field is left out.

  Answers `{:ok, credentials}` or `{:error, reason}`.
  """
  def recommended_credentials(%User{} = user) do
    with {:ok, key} <- Pesque.Keys.ensure(user.did),
         {:ok, rotation_keys} <- recommended_rotation_keys(user) do
      credentials = %{
        "verificationMethods" => %{"atproto" => Did.key_did(key.pub)},
        "services" => %{
          "atproto_pds" => %{
            "type" => "AtprotoPersonalDataServer",
            "endpoint" => Pesque.base_url()
          }
        },
        "alsoKnownAs" => ["at://" <> user.handle]
      }

      {:ok,
       if(rotation_keys,
         do: Map.put(credentials, "rotationKeys", rotation_keys),
         else: credentials
       )}
    end
  end

  defp recommended_rotation_keys(%User{did: "did:plc:" <> _} = user), do: rotation_key(user.did)
  defp recommended_rotation_keys(%User{}), do: {:ok, nil}

  # A rotation key is minted once and then read back. The file is the account's
  # only recovery path, so a second ask returns the key already on disk rather
  # than a new one the operation log does not know about.
  defp rotation_key(did) do
    case Keys.load_rotation(did) do
      {:ok, priv} -> {:ok, [Did.key_did(Secp256k1.public_from_private(priv))]}
      {:error, :enoent} -> create_rotation_key(did)
      {:error, reason} -> {:error, {:rotation_key_unreadable, reason}}
    end
  end

  defp create_rotation_key(did) do
    case Keys.create_rotation(did) do
      {:ok, %{pub: pub}} -> {:ok, [Did.key_did(pub)]}
      {:error, reason} -> {:error, {:rotation_key_unreadable, reason}}
    end
  end

  @doc """
  Issues the single-use token `sign_operation/2` spends.

  The lexicon emails this code to the account holder. There is no mail here
  and no email dependency, so the code goes to the operator instead: it is
  logged (the `token` metadata, info level) and mintable again through
  `pesque account plc-token`. A self-hosted PDS's account holder is its
  operator, which is the assumption the email flow stood on. Unlike the
  deletion token it is not answered in the response body: the code has to
  reach a human, and a body is read by the client library that asked, which
  has nowhere to put it. The log and the CLI are where the operator already
  works.

  The token is stored hashed, expires in 15 minutes, and is single use: the
  conditional update that spends it means two callers racing with one code
  produce one signature and one refusal.

  Answers `{:ok, %{token:, expires_at:}}` or `{:error, reason}`.
  """
  def request_operation_signature(%User{did: "did:plc:" <> _} = user) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    expires_at =
      DateTime.shift(DateTime.utc_now(), second: @plc_token_ttl_seconds)
      |> DateTime.truncate(:second)

    attrs = %{
      token_hash: Token.hash_token(token),
      did: user.did,
      expires_at: expires_at
    }

    case Token.changeset(attrs) |> Repo.insert() do
      {:ok, _row} ->
        Logger.info("plc operation token issued", did: user.did, token: token)
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, _changeset} ->
        {:error, :plc_token_failed}
    end
  end

  def request_operation_signature(%User{}), do: {:error, :not_a_plc_account}

  @doc """
  Signs a PLC operation over the account's stored one.

  The fields the request names replace the stored operation's own; anything
  absent carries forward, so a request naming only what changes signs a
  minimal operation. The moved-out credentials, which a client takes from the
  destination PDS's `getRecommendedDidCredentials`, arrive as the replacement
  values. `prev` points at the stored operation's CID and the signature is
  the account's rotation key's, the pair the directory will check. The signed
  operation is returned, not submitted and not stored: until the directory
  accepts it, nothing here has changed.

  The request is valid in shapes only, the way `submit_operation/2`'s checks
  match shapes: a malformed field is refused, and the endpoint, signing key
  and handle in the fields are the client's business, because the operation
  this signs is the one that moves the account somewhere else. An empty
  request is an error, not a re-signature of the stored operation: there is
  no token to spend, and the token is what keeps a signature from being
  minted by accident.

  Answers `{:ok, operation}` or `{:error, reason}`.
  """
  def sign_operation(%User{did: "did:plc:" <> _} = user, input) do
    with {:ok, token, patches} <- read_input(input),
         {:ok, row} <- fetch_token(user.did, token),
         {:ok, prev} <- decode_operation(user.plc_operation),
         {:ok, rotation_priv} <- load_rotation(user.did) do
      op = Operation.update(prev, patches, rotation_priv)

      if spend_token(row), do: {:ok, op}, else: {:error, :invalid_token}
    end
  end

  def sign_operation(%User{}, _input), do: {:error, :not_a_plc_account}

  defp read_input(input) when is_map(input) do
    with {:ok, patches} <- patches(input),
         {:ok, token} <- input_token(input) do
      {:ok, token, patches}
    end
  end

  defp read_input(_input), do: {:error, :plc_operation_invalid}

  # Only the operation's own fields are patched, so a field of the wrong shape
  # is refused rather than signed into the document. An explicit null is
  # absent, the way the reference PDS reads one.
  defp patches(input) do
    with :ok <- field_shapes(input) do
      {:ok, input |> Map.take(@plc_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  defp field_shapes(input) do
    with :ok <- string_list(input, "rotationKeys"),
         :ok <- string_list(input, "alsoKnownAs"),
         :ok <- object(input, "verificationMethods"),
         :ok <- object(input, "services") do
      :ok
    end
  end

  defp string_list(input, key) do
    case Map.fetch(input, key) do
      {:ok, nil} ->
        :ok

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, :plc_operation_invalid}

      {:ok, _other} ->
        {:error, :plc_operation_invalid}

      :error ->
        :ok
    end
  end

  defp object(input, key) do
    case Map.fetch(input, key) do
      {:ok, nil} -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, _other} -> {:error, :plc_operation_invalid}
      :error -> :ok
    end
  end

  # The token is the one request_operation_signature issued. A missing or
  # non-string one is the same "you have no code" answer, which is also what
  # an empty request becomes.
  defp input_token(%{"token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp input_token(_input), do: {:error, :plc_token_required}

  # Expiry is answered separately from validity, the way the deletion token's
  # is: a client told ExpiredToken asks for a new code instead of guessing
  # whether the one it holds is merely wrong.
  defp fetch_token(did, token) do
    case Repo.get_by(Token, token_hash: Token.hash_token(token)) do
      nil -> {:error, :invalid_token}
      %Token{did: ^did, used_at: nil} = row -> check_not_expired(row)
      %Token{} -> {:error, :invalid_token}
    end
  end

  defp check_not_expired(%Token{expires_at: expires_at} = row) do
    if DateTime.before?(expires_at, DateTime.utc_now()) do
      {:error, :expired_token}
    else
      {:ok, row}
    end
  end

  # Single use is a conditional update, not a read followed by a write, for
  # the reason the deletion token gives: two callers holding one code both
  # read it unused, and only the one whose update matches a row proceeds.
  defp spend_token(%Token{id: id}) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      from(t in Token, where: t.id == ^id and is_nil(t.used_at))
      |> Repo.update_all(set: [used_at: now])

    count == 1
  end

  @doc """
  Validates a signed PLC operation, submits it, and records it on the account.

  The checks are the three that keep the identity usable from here: the
  operation must point its PDS service at this server, name this server's
  signing key as the account's `atproto` method, and claim the account's
  handle. Anything else is refused before the directory sees it, so a rejected
  operation leaves the account row and the directory exactly as they were. The
  operation is written to the row only after the directory accepts it and its
  document resolves back to this server, so the stored operation is one the
  network agrees with.

  Answers `{:ok, did}` or `{:error, reason}`.
  """
  def submit_operation(%User{did: "did:plc:" <> _} = user, operation) do
    with :ok <- validate_operation(user, operation),
         :ok <- submit(user.did, operation),
         :ok <- verify_pds(user.did),
         {:ok, _user} <- store_operation(user, operation) do
      {:ok, user.did}
    end
  end

  def submit_operation(%User{}, _operation), do: {:error, :not_a_plc_account}

  defp validate_operation(user, operation) when is_map(operation) do
    with :ok <- validate_endpoint(operation),
         :ok <- validate_signing_key(user, operation),
         :ok <- validate_handle(user, operation) do
      :ok
    end
  end

  defp validate_operation(_user, _operation), do: {:error, :plc_operation_invalid}

  defp validate_endpoint(%{"services" => %{"atproto_pds" => %{"endpoint" => endpoint}}}) do
    if endpoint == Pesque.base_url(), do: :ok, else: {:error, :plc_endpoint_mismatch}
  end

  defp validate_endpoint(_operation), do: {:error, :plc_operation_invalid}

  defp validate_signing_key(%User{} = user, %{"verificationMethods" => %{"atproto" => key}}) do
    case Pesque.Keys.ensure(user.did) do
      {:ok, %{pub: pub}} ->
        if key == Did.key_did(pub), do: :ok, else: {:error, :plc_signing_key_mismatch}

      {:error, _reason} ->
        {:error, :key_unavailable}
    end
  end

  defp validate_signing_key(_user, _operation), do: {:error, :plc_operation_invalid}

  defp validate_handle(%User{handle: handle}, %{"alsoKnownAs" => also_known_as})
       when is_list(also_known_as) do
    if ("at://" <> handle) in also_known_as, do: :ok, else: {:error, :plc_handle_mismatch}
  end

  defp validate_handle(_user, _operation), do: {:error, :plc_operation_invalid}

  defp store_operation(%User{} = user, operation) do
    case user |> User.plc_operation_changeset(JSON.encode!(operation)) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :account_not_updated}
    end
  end

  defp submit(did, op), do: client().submit(did, op)

  defp client, do: Application.get_env(:pesque, :plc_client, Directory)

  defp claim_keys(did, repo_pub, repo_priv, rotation_pub, rotation_priv) do
    with {:ok, key} <- Keys.create_repo(did, repo_pub, repo_priv),
         {:ok, _rotation} <- Keys.create_rotation(did, rotation_pub, rotation_priv) do
      {:ok, key}
    end
  end

  defp decode_operation(nil), do: {:error, :plc_operation_missing}

  defp decode_operation(stored) do
    case JSON.decode(stored) do
      {:ok, op} when is_map(op) -> {:ok, op}
      _ -> {:error, :plc_operation_missing}
    end
  end

  defp load_rotation(did) do
    case Keys.load_rotation(did) do
      {:ok, priv} -> {:ok, priv}
      {:error, reason} -> {:error, {:rotation_key_unreadable, reason}}
    end
  end

  defp pds_endpoint(%{"service" => services}) when is_list(services) do
    case Enum.find(services, &pds_service?/1) do
      %{"serviceEndpoint" => endpoint} when is_binary(endpoint) -> {:ok, endpoint}
      _ -> {:error, :pds_missing}
    end
  end

  defp pds_endpoint(_document), do: {:error, :pds_missing}

  defp pds_service?(%{"id" => id, "type" => "AtprotoPersonalDataServer"}) when is_binary(id),
    do: String.ends_with?(id, "#atproto_pds")

  defp pds_service?(_service), do: false
end
