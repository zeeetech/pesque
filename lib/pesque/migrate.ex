defmodule Pesque.Migrate do
  @moduledoc """
  Moving an existing ATProto account onto this server.

  This automates the scriptable half of `docs/guides/migration.md`. The task
  runs on the new server, so the new-server half goes through the domain
  modules directly: the account row, the repo, the blobs, the keys and the PLC
  submission all happen here. Only the old PDS is spoken to over HTTP, through
  the `Pesque.Migrate.OldPds` client.

  The move stops at the identity step by design. This server does not implement
  `signPlcOperation` or `requestPlcOperationSignature`, so the old PDS signs the
  operation that carries the recommended credentials (on `bsky.social` that
  needs a code emailed to the account holder), and this side submits it.
  """

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.Car
  alias Pesque.Migrate.Http
  alias Pesque.Plc
  alias Pesque.RepoImport

  @doc """
  Moves the account named by `opts` onto this server.

  Required: `:old_pds` (base URL), `:handle`, `:email` and `:password` (the old
  PDS account password, reused as the new account's password). Not an app
  password: the PLC endpoints require a full-access session, which an app
  password never carries, so the old PDS answers `400 Bad token scope`.

  Seams: `:client` (default `Pesque.Migrate.Http`), `:prompt` (a 1-arity fun
  for the PLC email code, default `&IO.gets/1`), `:log` (a 1-arity fun,
  default `&IO.puts/1`) and `:plc_token` (a code already requested from the old
  PDS, for a caller with no terminal to prompt on; when present it is used
  instead of asking the old PDS to email a new one).

  Answers `:ok` on a completed move, or `{:error, reason}` at the first step
  that fails. Steps before the PLC submission can be retried: a second run
  reuses the account already created.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    client = Keyword.get(opts, :client, Http)
    prompt = Keyword.get(opts, :prompt, &IO.gets/1)
    log = Keyword.get(opts, :log, &IO.puts/1)
    plc_token = Keyword.get(opts, :plc_token)

    with {:ok, old_pds} <- fetch(opts, :old_pds),
         {:ok, handle} <- fetch(opts, :handle),
         {:ok, email} <- fetch(opts, :email),
         {:ok, password} <- fetch(opts, :password),
         {:ok, session} <- client.create_session(old_pds, handle, password),
         did = session.did,
         :ok <- note(log, "opened a session on #{old_pds} for #{handle}"),
         {:ok, _user} <- ensure_account(did, handle, email, password, log),
         :ok <- import_repo(client, old_pds, session.access_jwt, did, log),
         :ok <- import_blobs(client, old_pds, session.access_jwt, did, log),
         {:ok, user} <- current_user(did),
         {:ok, credentials} <- Plc.recommended_credentials(user),
         :ok <- note(log, "asking the old PDS to sign the identity"),
         {:ok, operation} <-
           move_identity(client, old_pds, session.access_jwt, credentials, prompt, plc_token),
         :ok <- note(log, "submitting the plc operation"),
         {:ok, _did} <- Plc.submit_operation(user, operation),
         :ok <- activate(client, old_pds, session.access_jwt, did, log) do
      :ok
    end
  end

  @doc """
  Asks the old PDS to email the PLC operation signature code, without running
  the move.

  The move stops at the PLC step for a code the account holder receives by
  email, and a caller with no terminal cannot answer the prompt that follows.
  Splitting the request out lets that caller get the code first, then hand it
  back through `:plc_token`.
  """
  @spec request_plc_code(keyword()) :: :ok | {:error, term()}
  def request_plc_code(opts) do
    client = Keyword.get(opts, :client, Http)

    with {:ok, old_pds} <- fetch(opts, :old_pds),
         {:ok, handle} <- fetch(opts, :handle),
         {:ok, password} <- fetch(opts, :password),
         {:ok, session} <- client.create_session(old_pds, handle, password),
         :ok <- client.request_plc_signature(old_pds, session.access_jwt) do
      :ok
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  # A progress line carried inside a `with`, so a step can announce itself
  # without pulling the step out into its own function.
  defp note(log, message) do
    log.(message)
    :ok
  end

  # A re-run reuses the account a previous run created, so the account step is
  # the one place a migration is resumable rather than one-shot.
  defp ensure_account(did, handle, email, password, log) do
    case Accounts.get_user(did) do
      %User{} = user ->
        log.("account #{did} already exists; reusing it")
        {:ok, user}

      nil ->
        case Accounts.create_imported_account(handle, email, password, did) do
          {:ok, user} ->
            log.("created account #{did} (deactivated)")
            {:ok, user}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp import_repo(client, old_pds, access_jwt, did, log) do
    with {:ok, car} <- client.get_repo(old_pds, access_jwt, did),
         {:ok, imported} <- Car.decode_repo(car),
         {:ok, _did} <- RepoImport.persist_import(did, imported) do
      log.("imported the repo for #{did}")
      :ok
    end
  end

  defp import_blobs(client, old_pds, access_jwt, did, log) do
    with {:ok, cids} <- client.list_blobs(old_pds, access_jwt, did) do
      total = length(cids)
      log.("importing #{pluralize(total, "blob")} for #{did}")

      case import_each_blob(client, old_pds, did, cids, log, 0, total) do
        {:ok, count} ->
          log.("imported #{pluralize(count, "blob")} for #{did}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp import_each_blob(_client, _old_pds, _did, [], _log, count, _total), do: {:ok, count}

  defp import_each_blob(client, old_pds, did, [cid | rest], log, count, total) do
    with {:ok, bytes, content_type} <- client.get_blob(old_pds, did, cid),
         {:ok, _blob} <- Blob.upload(did, bytes, content_type) do
      done = count + 1
      log.("imported #{done} of #{pluralize(total, "blob")}")
      import_each_blob(client, old_pds, did, rest, log, done, total)
    end
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  # A supplied code is used as is, so a caller that requested it out of band
  # does not make the old PDS email a second one (which would invalidate the
  # first). Without one, the code is requested and read from the prompt.
  defp move_identity(client, old_pds, access_jwt, credentials, prompt, plc_token) do
    with {:ok, token} <- plc_code(client, old_pds, access_jwt, prompt, plc_token) do
      client.sign_plc_operation(old_pds, access_jwt, credentials, token)
    end
  end

  defp plc_code(_client, _old_pds, _access_jwt, _prompt, token)
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp plc_code(client, old_pds, access_jwt, prompt, _token) do
    case client.request_plc_signature(old_pds, access_jwt) do
      :ok -> prompt_code(prompt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_code(prompt) do
    case prompt.("Enter the code from your email: ") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :plc_code_missing}
    end
  end

  defp current_user(did) do
    case Accounts.get_user(did) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :account_missing}
    end
  end

  defp activate(client, old_pds, access_jwt, did, log) do
    with {:ok, user} <- current_user(did),
         {:ok, _did} <- Accounts.activate_account(user),
         :ok <- client.deactivate(old_pds, access_jwt) do
      log.("activated #{did} and deactivated the old PDS account")
      :ok
    end
  end
end

defmodule Pesque.Migrate.OldPds do
  @moduledoc """
  The old PDS, as a migration sees it: the ATProto endpoints a move reads from,
  and the two it writes to.

  A behaviour so the orchestration in `Pesque.Migrate` is testable without a
  network. `Pesque.Migrate.Http` is the real one.
  """

  @type reason :: term()

  @doc "Authenticates against the old PDS and answers its session."
  @callback create_session(base_url :: String.t(), handle :: String.t(), password :: String.t()) ::
              {:ok, %{access_jwt: String.t(), did: String.t(), handle: String.t()}}
              | {:error, reason}

  @doc "Fetches a repo as CAR bytes."
  @callback get_repo(base_url :: String.t(), access_jwt :: String.t(), did :: String.t()) ::
              {:ok, binary()} | {:error, reason}

  @doc "Lists the blob CIDs a repo holds."
  @callback list_blobs(base_url :: String.t(), access_jwt :: String.t(), did :: String.t()) ::
              {:ok, [String.t()]} | {:error, reason}

  @doc "Fetches one blob's bytes and its content type. Public on the old PDS."
  @callback get_blob(base_url :: String.t(), did :: String.t(), cid :: String.t()) ::
              {:ok, binary(), String.t()} | {:error, reason}

  @doc "Asks the old PDS to email a PLC operation signature code."
  @callback request_plc_signature(base_url :: String.t(), access_jwt :: String.t()) ::
              :ok | {:error, reason}

  @doc "Has the old PDS sign a PLC operation over `credentials`."
  @callback sign_plc_operation(
              base_url :: String.t(),
              access_jwt :: String.t(),
              credentials :: map(),
              token :: String.t()
            ) :: {:ok, map()} | {:error, reason}

  @doc "Deactivates the account on the old PDS."
  @callback deactivate(base_url :: String.t(), access_jwt :: String.t()) ::
              :ok | {:error, reason}
end

defmodule Pesque.Migrate.Http do
  @moduledoc """
  The real old-PDS client, over `:httpc`.

  The same shape as `Pesque.Doctor` and `Pesque.OAuth.Fetch`: `:inets` and
  `:ssl` rather than a client library, TLS verified, and binary bodies. A read
  follows redirects, because `bsky.social` answers a sync read with a 302 to the
  account's own PDS host; a write does not. Every failure is an
  `{:error, reason}` tuple, never a raise.

  `createSession` and `signPlcOperation` post JSON and decode a field from the
  answer; the `sync.*` reads take binary bodies, and `getBlob` also reads the
  response's content type. `requestPlcOperationSignature` takes no input, so it
  posts an empty body: the endpoint rejects even `{}`. Bearer auth is sent where
  a token is passed; `getBlob` is public on the old PDS, so its callback takes
  no token.
  """

  @behaviour Pesque.Migrate.OldPds

  @connect_timeout 5_000
  @timeout 30_000

  @impl true
  def create_session(base_url, handle, password) do
    body = JSON.encode!(%{"identifier" => handle, "password" => password})

    with {:ok, _headers, response} <-
           post(base_url, "/xrpc/com.atproto.server.createSession", nil, body),
         {:ok, session} <- session(response) do
      {:ok, session}
    end
  end

  @impl true
  def get_repo(base_url, access_jwt, did) do
    path = "/xrpc/com.atproto.sync.getRepo?did=" <> encode(did)

    with {:ok, _headers, body} <- get(base_url, path, access_jwt) do
      {:ok, body}
    end
  end

  @impl true
  def list_blobs(base_url, access_jwt, did) do
    path = "/xrpc/com.atproto.sync.listBlobs?did=" <> encode(did)

    with {:ok, _headers, body} <- get(base_url, path, access_jwt),
         {:ok, cids} <- cids(body) do
      {:ok, cids}
    end
  end

  @impl true
  def get_blob(base_url, did, cid) do
    path = "/xrpc/com.atproto.sync.getBlob?did=#{encode(did)}&cid=#{encode(cid)}"

    with {:ok, headers, body} <- get(base_url, path, nil) do
      {:ok, body, content_type(headers)}
    end
  end

  @impl true
  def request_plc_signature(base_url, access_jwt) do
    with {:ok, _headers, _body} <-
           post(
             base_url,
             "/xrpc/com.atproto.identity.requestPlcOperationSignature",
             access_jwt
           ) do
      :ok
    end
  end

  @impl true
  def sign_plc_operation(base_url, access_jwt, credentials, token) do
    body = JSON.encode!(Map.merge(credentials, %{"token" => token}))

    with {:ok, _headers, response} <-
           post(base_url, "/xrpc/com.atproto.server.signPlcOperation", access_jwt, body),
         {:ok, operation} <- operation(response) do
      {:ok, operation}
    end
  end

  @impl true
  def deactivate(base_url, access_jwt) do
    with {:ok, _headers, _body} <-
           post(base_url, "/xrpc/com.atproto.server.deactivateAccount", access_jwt, "{}") do
      :ok
    end
  end

  defp session(body) do
    case JSON.decode(body) do
      {:ok, %{"accessJwt" => jwt, "did" => did, "handle" => handle}}
      when is_binary(jwt) and is_binary(did) and is_binary(handle) ->
        {:ok, %{access_jwt: jwt, did: did, handle: handle}}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp cids(body) do
    case JSON.decode(body) do
      {:ok, %{"cids" => cids}} when is_list(cids) -> {:ok, cids}
      _ -> {:error, :invalid_response}
    end
  end

  defp operation(body) do
    case JSON.decode(body) do
      {:ok, %{"operation" => operation}} when is_map(operation) -> {:ok, operation}
      _ -> {:error, :invalid_response}
    end
  end

  defp post(base_url, path, access_jwt, body) do
    request(:post, url(base_url, path), headers(access_jwt), ~c"application/json", body)
  end

  # An endpoint whose lexicon declares no input rejects any body, even `{}`
  # ("A request body was provided when none was expected"), so this posts one
  # that is empty.
  defp post(base_url, path, access_jwt) do
    request(:post, url(base_url, path), headers(access_jwt), ~c"application/json", [])
  end

  defp get(base_url, path, access_jwt) do
    request(:get, url(base_url, path), headers(access_jwt), nil, nil)
  end

  defp request(method, url, headers, content_type, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request =
      case method do
        :get -> {String.to_charlist(url), headers}
        :post -> {String.to_charlist(url), headers, content_type, body}
      end

    # bsky.social answers a sync read with a 302 to the account's own PDS host
    # (`puffball.us-east.host.bsky.network` and friends), which then serves the
    # bytes. So a GET follows redirects; a write does not, since bsky proxies
    # the session and identity calls rather than redirecting them.
    options = [
      connect_timeout: @connect_timeout,
      timeout: @timeout,
      ssl: ssl_options(),
      autoredirect: method == :get
    ]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}}
      when status in 200..299 ->
        {:ok, response_headers, IO.iodata_to_binary(response_body)}

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, old_pds_status(status, IO.iodata_to_binary(body))}

      {:error, reason} ->
        {:error, {:old_pds_unreachable, reason}}
    end
  end

  # The old PDS reports an XRPC failure as {"error": ..., "message": ...}. Carry
  # the server's own message so a failed step names the reason instead of a bare
  # status; the move runs against another operator's server, so its words are
  # worth more than ours.
  defp old_pds_status(status, body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) ->
        {:old_pds_status, status, message}

      _ ->
        {:old_pds_status, status}
    end
  end

  defp headers(nil), do: []

  defp headers(token),
    do: [{~c"authorization", String.to_charlist("Bearer " <> token)}]

  defp content_type(headers) do
    Enum.find_value(headers, "application/octet-stream", fn {name, value} ->
      if name |> to_string() |> String.downcase() == "content-type", do: to_string(value)
    end)
  end

  defp url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  defp encode(value), do: URI.encode_www_form(value)

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
