defmodule Pesque.Migrate do
  @moduledoc """
  Moving an existing ATProto account onto this server.

  This automates the scriptable half of the move in `docs/operations.md`
  ("Moving an account in"). The task runs on the new server, so the new-server
  half goes through the domain modules directly: the account row, the repo,
  the blobs, the keys and the PLC submission all happen here. Only the old
  PDS is spoken to over HTTP, through the `Pesque.Migrate.OldPds` client.

  The signing stays with the old PDS: it holds the rotation key, so it signs
  the operation that carries the recommended credentials, and this side
  submits it. On `bsky.social` the old PDS emails a code to the account
  holder; on a pesque old PDS the code is surfaced to that server's operator
  instead (see `docs/operations.md`).
  """

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Blob
  alias Pesque.Car
  alias Pesque.Crawl
  alias Pesque.Events
  alias Pesque.Migrate.Http
  alias Pesque.Plc
  alias Pesque.RepoImport

  @doc """
  Moves the account named by `opts` onto this server.

  Required: `:old_pds` (base URL), `:handle`, `:email` and `:password` (the old
  PDS account password, reused as the new account's password). Not an app
  password: the PLC endpoints require a full-access session, which an app
  password never carries, so the old PDS answers `400 Bad token scope`.

  On a server whose registration is closed the move also needs `:invite_code`:
  the code is claimed when the account row is created, and without one the
  account step answers `{:error, :invalid_invite_code}`.

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
    invite_code = Keyword.get(opts, :invite_code)

    with {:ok, old_pds} <- fetch(opts, :old_pds),
         {:ok, handle} <- fetch(opts, :handle),
         {:ok, email} <- fetch(opts, :email),
         {:ok, password} <- fetch(opts, :password),
         {:ok, session} <- client.create_session(old_pds, handle, password),
         did = session.did,
         :ok <- note(log, "opened a session on #{old_pds} for #{handle}"),
         {:ok, _user} <- ensure_account(did, handle, email, password, invite_code, log),
         :ok <- import_repo(client, old_pds, session.access_jwt, did, log),
         :ok <- import_blobs(client, old_pds, session.access_jwt, did, log),
         {:ok, user} <- current_user(did),
         {:ok, credentials} <- Plc.recommended_credentials(user),
         :ok <- note(log, "asking the old PDS to sign the identity"),
         {:ok, operation} <-
           move_identity(client, old_pds, session.access_jwt, credentials, prompt, plc_token),
         :ok <- note(log, "submitting the plc operation"),
         {:ok, _did} <- Plc.submit_operation(user, operation),
         :ok <- announce_identity(user, log),
         :ok <- activate(client, old_pds, session.access_jwt, did, log),
         :ok <- announce_crawl(log) do
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
  defp ensure_account(did, handle, email, password, invite_code, log) do
    case Accounts.get_user(did) do
      %User{} = user ->
        log.("account #{did} already exists; reusing it")
        {:ok, user}

      nil ->
        # An option is built only when a code was given: with none, the insert
        # claims nothing, which is what a caller with no code has always meant.
        opts = if invite_code, do: [invite_code: invite_code], else: []

        case Accounts.create_imported_account(handle, email, password, did, opts) do
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
    done = count + 1

    case import_blob(client, old_pds, did, cid) do
      :kept ->
        log.("kept #{done} of #{pluralize(total, "blob")} (already stored)")
        import_each_blob(client, old_pds, did, rest, log, done, total)

      :imported ->
        log.("imported #{done} of #{pluralize(total, "blob")}")
        import_each_blob(client, old_pds, did, rest, log, done, total)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A blob a previous run already stored is not fetched again, so a retry after
  # a later step failed does not re-download the whole repo over a link that has
  # already proven slow.
  defp import_blob(client, old_pds, did, cid) do
    if Blob.stored?(did, cid) do
      :kept
    else
      with {:ok, bytes, content_type} <- client.get_blob(old_pds, did, cid),
           {:ok, _blob} <- Blob.upload(did, bytes, content_type) do
        :imported
      end
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

  # The spec pairs the identity update with an #identity event once the DID
  # document names this server: a consumer keyed on the handle would otherwise
  # keep pointing the old one at the old PDS. The PLC operation is submitted
  # above, so this server is the DID's current host by the time the frame goes
  # out, which is the condition the spec puts on the event.
  defp announce_identity(user, log) do
    Events.emit_identity(user.did, user.handle)
    log.("announced the identity for #{user.handle}")
    :ok
  end

  defp activate(client, old_pds, access_jwt, did, log) do
    with {:ok, user} <- current_user(did),
         {:ok, _did} <- Accounts.activate_account(user),
         :ok <- client.deactivate(old_pds, access_jwt) do
      # The old PDS's deactivation is the last account event for the DID that is
      # not this PDS's. Re-announce after it, so this PDS's activation goes out
      # last: a consumer that applies the old PDS's deactivation (the spec says
      # it should not, but the AppView does) otherwise ends with the account
      # marked deactivated even though it is active here.
      Accounts.announce_active(did)
      log.("activated #{did} and deactivated the old PDS account")
      :ok
    end
  end

  # A relay learns the account is active only from a live frame, and it hears a
  # live frame only if it is already crawling this server. The boot announcement
  # asked once; a migration that leaves the account active but un-crawled is the
  # failure this asks again for, at the end of the move.
  defp announce_crawl(log) do
    case Pesque.crawlers() do
      [] ->
        log.("no crawler configured, so no relay was re-asked to crawl this server")

      crawlers ->
        Crawl.request_all()
        log.("asked #{Enum.join(crawlers, ", ")} to crawl this server")
    end

    :ok
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
  The real old-PDS client.

  The old PDS is a URL the account holder names, so it is fetched the way every
  other stranger-named URL is: `Pesque.OAuth.Fetch` is the transport, which is
  https only, TLS verified, refuses a private or loopback address, and caps the
  response. What differs is redirects: `bsky.social` answers a sync read with a
  302 to the account's own PDS host, and the guard will not follow one, because
  a redirect is a second URL. So the hop is followed here, and every hop goes
  back through the transport, which checks its address the way it checked the
  first.

  `createSession` and `signPlcOperation` post JSON and decode a field from the
  answer; the `sync.*` reads take binary bodies, and `getBlob` also reads the
  response's content type. `requestPlcOperationSignature` takes no input, so it
  posts an empty body: the endpoint rejects even `{}`. Bearer auth is sent where
  a token is passed; `getBlob` is public on the old PDS, so its callback takes
  no token. Every failure is an `{:error, reason}` tuple, never a raise.
  """

  @behaviour Pesque.Migrate.OldPds

  @connect_timeout 5_000
  @timeout 30_000

  # The JSON answers are small. The two reads that are not are capped by the
  # number the matching write side accepts, so a read cannot pull in more than an
  # import or an upload would take.
  @json_max_bytes 1_048_576

  # A read follows redirects, and a chain is a second URL each time, so it is
  # bounded.
  @max_redirects 5

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

    # The whole repo arrives as one CAR, so the read is capped by what an import
    # would take rather than by the small JSON bound.
    with {:ok, _headers, body} <-
           get(base_url, path, access_jwt, Pesque.repo_import_max_bytes()) do
      {:ok, body}
    end
  end

  @impl true
  def list_blobs(base_url, access_jwt, did) do
    pages(base_url, access_jwt, did, nil, [])
  end

  # listBlobs answers one page (500 by default, 1000 at most) plus a cursor, and
  # a repo can hold thousands of blobs, so read every page rather than stopping
  # at the first: a short answer here is a silently incomplete move.
  defp pages(base_url, access_jwt, did, cursor, acc) do
    path = "/xrpc/com.atproto.sync.listBlobs?did=" <> encode(did) <> cursor_query(cursor)

    with {:ok, _headers, body} <- get(base_url, path, access_jwt, @json_max_bytes),
         {:ok, cids, next} <- blob_page(body) do
      acc = [cids | acc]

      case next do
        nil -> {:ok, acc |> Enum.reverse() |> List.flatten()}
        cursor -> pages(base_url, access_jwt, did, cursor, acc)
      end
    end
  end

  defp cursor_query(nil), do: ""
  defp cursor_query(cursor), do: "&cursor=" <> encode(cursor)

  @impl true
  def get_blob(base_url, did, cid) do
    path = "/xrpc/com.atproto.sync.getBlob?did=#{encode(did)}&cid=#{encode(cid)}"

    with {:ok, headers, body} <- get(base_url, path, nil, Pesque.blob_max_bytes()) do
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

    # The identity namespace, not server: bsky's shard answers `501 Method Not
    # Implemented` for the old `com.atproto.server.signPlcOperation` alias.
    with {:ok, _headers, response} <-
           post(base_url, "/xrpc/com.atproto.identity.signPlcOperation", access_jwt, body),
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

  # A page of listBlobs: its CIDs and the cursor to the next page, if any.
  defp blob_page(body) do
    case JSON.decode(body) do
      {:ok, %{"cids" => cids} = page} when is_list(cids) ->
        case page do
          %{"cursor" => cursor} when is_binary(cursor) -> {:ok, cids, cursor}
          _ -> {:ok, cids, nil}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  defp operation(body) do
    case JSON.decode(body) do
      {:ok, %{"operation" => operation}} when is_map(operation) -> {:ok, operation}
      _ -> {:error, :invalid_response}
    end
  end

  defp post(base_url, path, access_jwt, body) do
    request(
      :post,
      url(base_url, path),
      headers(access_jwt),
      "application/json",
      body,
      @json_max_bytes
    )
  end

  # An endpoint whose lexicon declares no input rejects any body, even `{}`
  # ("A request body was provided when none was expected"), so this posts one
  # that is empty.
  defp post(base_url, path, access_jwt) do
    request(
      :post,
      url(base_url, path),
      headers(access_jwt),
      "application/json",
      [],
      @json_max_bytes
    )
  end

  defp get(base_url, path, access_jwt, max_bytes) do
    request(:get, url(base_url, path), headers(access_jwt), nil, nil, max_bytes)
  end

  defp request(method, url, headers, content_type, body, max_bytes) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    follow(method, url, headers, content_type, body, max_bytes, 0)
  end

  # bsky.social answers a sync read with a 302 to the account's own PDS host
  # (`puffball.us-east.host.bsky.network` and friends), which then serves the
  # bytes. So a GET follows redirects; a write does not, since bsky proxies the
  # session and identity calls rather than redirecting them.
  #
  # Every hop goes back through the transport, so the scheme and the address of
  # each one are checked the way the first was. Following the redirect inside
  # `:httpc` was the guard bypassed: a redirect is a second URL, and where it
  # pointed was never looked at.
  defp follow(:get, url, headers, content_type, body, max_bytes, hops)
       when hops < @max_redirects do
    case hop(:get, url, headers, content_type, body, max_bytes) do
      {:redirect, location} ->
        follow(:get, absolute(url, location), headers, content_type, body, max_bytes, hops + 1)

      answer ->
        answer
    end
  end

  defp follow(:get, _url, _headers, _content_type, _body, _max_bytes, _hops),
    do: {:error, {:old_pds_unreachable, :too_many_redirects}}

  defp follow(:post, url, headers, content_type, body, max_bytes, _hops) do
    case hop(:post, url, headers, content_type, body, max_bytes) do
      {:redirect, location} -> {:error, {:old_pds_status, 302, location}}
      answer -> answer
    end
  end

  defp hop(method, url, headers, content_type, body, max_bytes) do
    sent = if content_type, do: [{"content-type", content_type} | headers], else: headers

    case transport().request(
           URI.parse(url),
           method,
           sent,
           body,
           max_bytes: max_bytes,
           connect_timeout: @connect_timeout,
           timeout: @timeout
         ) do
      {:ok, status, response_headers, response_body} when status in 200..299 ->
        {:ok, response_headers, response_body}

      {:ok, status, response_headers, response_body} when status in 300..399 ->
        case location(response_headers) do
          location when is_binary(location) -> {:redirect, location}
          _none -> {:error, old_pds_status(status, response_body)}
        end

      {:ok, status, _response_headers, response_body} ->
        {:error, old_pds_status(status, response_body)}

      {:error, reason} ->
        {:error, {:old_pds_unreachable, reason}}
    end
  end

  # A redirect's target is resolved against the URL that answered, so a relative
  # Location is followed to the right host.
  defp absolute(url, location), do: url |> URI.parse() |> URI.merge(location) |> URI.to_string()

  defp location(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "location", do: value
    end)
  end

  # The hardened client, injectable the way the entryway injects its own. A test
  # that drives this module at the socket needs a transport that will speak to a
  # throwaway server on loopback, which the guard refuses by design.
  defp transport, do: Application.get_env(:pesque, :migrate_fetch, Pesque.OAuth.Fetch)

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

  defp headers(token), do: [{"authorization", "Bearer " <> token}]

  defp content_type(headers) do
    Enum.find_value(headers, "application/octet-stream", fn {name, value} ->
      if name |> to_string() |> String.downcase() == "content-type", do: to_string(value)
    end)
  end

  defp url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  defp encode(value), do: URI.encode_www_form(value)
end
