defmodule Pesque.Cli.Account do
  @moduledoc """
  The account verbs, wired straight to the domain: show, create, list, delete,
  takedown, activate, reset-password, plc-token and the app-password verbs.

  The delete summary prints from `Accounts.describe_deletion/1` on both the
  dry run and the real run, so the rehearsal reads the same facts the action
  acts on.
  """

  use Gettext, backend: PesqueWeb.Gettext

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Cli.Input
  alias Pesque.Cli.Output
  alias Pesque.Cli.Runtime
  alias Pesque.Plc
  alias Pesque.Cli.Report
  alias Pesque.RepoStore

  @usage """
  usage: pesque account <subcommand> [flags]

    create --handle H --email E [--identity web|plc] [--public-ip IP]
    list [--status active|deactivated] [--grep PATTERN]
    show (--did D | --handle H)
    delete --did D | --handle H [--dry-run]
    takedown --did D | --handle H
    activate --did D | --handle H
    reset-password --did D | --handle H
    plc-token --did D | --handle H
    email-token --did D | --handle H
    reset-token --did D | --handle H
    app-passwords --did D | --handle H
    revoke-app-password --did D | --handle H --name N

  Plain inputs come from the flag, then the conventional environment
  (ACCOUNT_HANDLE, ACCOUNT_EMAIL), then a prompt. Passwords come from a
  no-echo prompt or a line on stdin, never a flag or the environment.
  --grep matches a substring, case-insensitively, over did, handle and email.
  """

  # The most specific usage each subcommand answers `--help` with, written
  # out so a new subcommand has to answer the help question to join. The
  # account-level @usage above stays the answer for `account --help` and the
  # catch-all.
  @sub_usage %{
    "create" => """
    usage: pesque account create --handle H --email E [--identity web|plc] [--public-ip IP]

    The handle and email come from the flag, then the conventional
    environment (ACCOUNT_HANDLE, ACCOUNT_EMAIL), then a prompt. The password
    comes from a no-echo prompt or a line on stdin, never a flag.

    --identity picks the DID method. Under single it defaults to web (the
    account is the server's own did:web); plc mints a fresh did:plc instead.
    Under multi accounts are always did:plc and web is refused.

    --public-ip only changes the A record example printed after creation.
    """,
    "list" => """
    usage: pesque account list [--status active|deactivated] [--grep PATTERN]

    --grep matches a substring, case-insensitively, over did, handle and
    email. Both filters compose with --json.
    """,
    "show" => "usage: pesque account show (--did D | --handle H)\n",
    "delete" => """
    usage: pesque account delete --did D | --handle H [--dry-run]

    --dry-run prints what would go and changes nothing. The real run asks
    for the account password (a no-echo prompt or a line on stdin).
    """,
    "takedown" => "usage: pesque account takedown --did D | --handle H\n",
    "activate" => "usage: pesque account activate --did D | --handle H\n",
    "reset-password" => """
    usage: pesque account reset-password --did D | --handle H

    The new password comes from a no-echo prompt or a line on stdin, never a
    flag or the environment.
    """,
    "plc-token" => "usage: pesque account plc-token --did D | --handle H\n",
    "email-token" => "usage: pesque account email-token --did D | --handle H\n",
    "reset-token" => "usage: pesque account reset-token --did D | --handle H\n",
    "app-passwords" => "usage: pesque account app-passwords --did D | --handle H\n",
    "revoke-app-password" =>
      "usage: pesque account revoke-app-password --did D | --handle H --name N\n"
  }

  # --did and --handle name the same account.
  @identifier_switches [did: :string, handle: :string]

  # The read verbs' published JSON surface: stdout carries the data, stderr
  # the prose, and the field names are the storage vocabulary.
  @json [json: :boolean]

  def run(["--help"]), do: {:help, @usage}

  def run(["create" | argv]) do
    with {:ok, opts, []} <-
           Input.options(
             argv,
             [handle: :string, email: :string, identity: :string, public_ip: :string],
             @sub_usage["create"]
           ),
         {:ok, handle} <- Input.text(opts, :handle, "ACCOUNT_HANDLE", "handle: "),
         {:ok, email} <- Input.text(opts, :email, "ACCOUNT_EMAIL", "email: "),
         {:ok, method} <- identity_method(opts[:identity]),
         {:ok, password} <-
           Input.password("Password for the new account (at least 8 characters): "),
         :ok <- Runtime.start() do
      case Accounts.create_account(handle, email, password, identity: method) do
        {:ok, account} ->
          Report.print_account(account, public_ip: opts[:public_ip])
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --identity web|plc is parsed in run(["create"|...]); the helpers live with
  # the other private functions below, after the run/1 clauses.

  def run(["list" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, [status: :string, grep: :string] ++ @json, @sub_usage["list"]),
         :ok <- check_status(opts[:status]),
         :ok <- Runtime.start() do
      users = filtered_users(opts)

      if opts[:json] do
        Output.json(%{"accounts" => Enum.map(users, &user_json/1)})
      else
        IO.puts(header())
        Enum.each(users, &print_row/1)
      end

      :ok
    end
  end

  def run(["show" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches ++ @json, @sub_usage["show"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      if opts[:json] do
        Output.json(%{"account" => show_json(user)})
      else
        print_show(user)
      end

      :ok
    end
  end

  def run(["delete" | argv]) do
    with {:ok, opts, []} <-
           Input.options(
             argv,
             @identifier_switches ++ [dry_run: :boolean],
             @sub_usage["delete"]
           ),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      # Both paths print the same before-picture, read once through
      # describe_deletion/1. The dry run stops there; the real run goes on to
      # the password gate.
      print_deletion_summary(Accounts.describe_deletion(user))

      if opts[:dry_run] do
        IO.puts(gettext("dry run: nothing was deleted"))
        :ok
      else
        delete(user)
      end
    end
  end

  def run(["takedown" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["takedown"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      case Accounts.deactivate_account(user) do
        {:ok, did} ->
          IO.puts("deactivated #{user.handle || did}; the repo, key and rows are kept")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(["activate" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["activate"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      case Accounts.activate_account(user) do
        {:ok, did} ->
          IO.puts("activated #{user.handle || did}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(["reset-password" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["reset-password"]),
         {:ok, identifier} <- identifier(opts),
         {:ok, password} <- Input.password("new password: "),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier),
         :ok <- Accounts.reset_password(user, password) do
      IO.puts("password updated for #{user.handle || user.did}; every session it held is revoked")
      :ok
    end
  end

  # The code the spec emails the account holder. On a server with no mail it
  # reaches the operator through the log or here, and it is what
  # signPlcOperation spends.
  def run(["plc-token" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["plc-token"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier),
         {:ok, %{token: token, expires_at: expires_at}} <- Plc.request_operation_signature(user) do
      IO.puts("plc operation token for #{user.did}: #{token}")
      IO.puts("expires at #{DateTime.to_iso8601(expires_at)}; single use,")
      IO.puts("then request another. signPlcOperation spends it.")
      :ok
    end
  end

  # The email code the spec sends the account holder. Like the plc token it
  # reaches the operator through the log; this verb mints another on demand.
  # One code serves both email flows: confirmEmail spends it to confirm the
  # address, and updateEmail spends it when a confirmed address is being moved.
  def run(["email-token" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["email-token"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier),
         {:ok, %{token: token, expires_at: expires_at}} <-
           Accounts.request_email_confirmation(user) do
      IO.puts("email token for #{user.did}: #{token}")
      IO.puts("expires at #{DateTime.to_iso8601(expires_at)}; single use,")
      IO.puts("then request another. confirmEmail or updateEmail spends it.")
      :ok
    end
  end

  # The reset code the spec emails the account holder. requestPasswordReset is
  # anonymous and answers nothing, so on a server with no mail this verb is how
  # the operator mints one; resetPassword spends it.
  def run(["reset-token" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @sub_usage["reset-token"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier),
         {:ok, %{token: token, expires_at: expires_at}} <-
           Accounts.request_password_reset(user) do
      IO.puts("password reset token for #{user.did}: #{token}")
      IO.puts("expires at #{DateTime.to_iso8601(expires_at)}; single use,")
      IO.puts("then request another. resetPassword spends it.")
      :ok
    end
  end

  # The operator's view of a user's app passwords: the XRPC endpoints need a
  # session the operator does not hold, so the recovery path (a user reporting
  # a compromised app password) is here. Names and privileges only; the
  # passwords themselves are unrecoverable by construction.
  def run(["app-passwords" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches ++ @json, @sub_usage["app-passwords"]),
         {:ok, identifier} <- identifier(opts),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      rows = Accounts.list_app_passwords(user.did)

      if opts[:json] do
        Output.json(%{"app_passwords" => Enum.map(rows, &app_password_json/1)})
      else
        print_app_passwords(user, rows)
      end

      :ok
    end
  end

  def run(["revoke-app-password" | argv]) do
    with {:ok, opts, []} <-
           Input.options(
             argv,
             @identifier_switches ++ [name: :string],
             @sub_usage["revoke-app-password"]
           ),
         {:ok, identifier} <- identifier(opts),
         {:ok, name} <- Input.text(opts, :name, "APP_PASSWORD_NAME", "name: "),
         :ok <- Runtime.start(),
         {:ok, user} <- resolve(identifier) do
      # Distinguish "nothing to do" from a real revoke; both exit 0 (the
      # endpoint is idempotent the same way).
      if Enum.any?(Accounts.list_app_passwords(user.did), &(&1.name == name)) do
        :ok = Accounts.revoke_app_password(user, name)

        IO.puts(
          "revoked app password #{name} for #{user.handle || user.did}; its sessions are revoked"
        )
      else
        IO.puts("no app password named #{name} for #{user.handle || user.did} (nothing to do)")
      end

      :ok
    end
  end

  def run(_argv), do: {:usage, @usage}

  # --identity web|plc. Absent means the mode default (single -> web, multi ->
  # plc), which create_account/4 applies when no :identity option is given. A
  # value other than web or plc is a usage error, not a domain reason.
  defp identity_method(nil), do: {:ok, nil}
  defp identity_method("web"), do: {:ok, :web}
  defp identity_method("plc"), do: {:ok, :plc}

  defp identity_method(other),
    do: {:usage, "--identity must be web or plc, got: #{other}\n\n" <> @sub_usage["create"]}

  # repo_did/1 matches a DID exactly and a handle case-insensitively, so the
  # verbs need no second resolver.
  defp resolve(identifier) do
    with {:ok, did} <- Accounts.repo_did(identifier) do
      case Accounts.get_user(did) do
        %User{} = user -> {:ok, user}
        nil -> {:error, :not_found}
      end
    end
  end

  defp identifier(opts) do
    cond do
      opts[:did] && opts[:handle] -> {:usage, "give --did or --handle, not both\n\n" <> @usage}
      opts[:did] -> {:ok, opts[:did]}
      opts[:handle] -> {:ok, opts[:handle]}
      true -> {:usage, "one of --did or --handle is required\n\n" <> @usage}
    end
  end

  defp header do
    String.pad_trailing("did", 38) <>
      String.pad_trailing("handle", 32) <>
      String.pad_trailing("email", 32) <> "deactivated at"
  end

  defp print_row(%{did: did, handle: handle, email: email, deactivated_at: deactivated_at}) do
    deactivated = if deactivated_at, do: DateTime.to_iso8601(deactivated_at), else: "-"

    (String.pad_trailing(did, 38) <>
       String.pad_trailing(handle || "-", 32) <>
       String.pad_trailing(email || "-", 32) <> deactivated)
    |> IO.puts()
  end

  # Filtering lives here, not in SQL: a PDS's account list is small, and the
  # moment it is not, that becomes a RepoStore query (see the C7 notes).
  defp filtered_users(opts) do
    opts[:status]
    |> status_scope()
    |> filter_grep(opts[:grep])
  end

  # list_users/0 answers active beside the deactivation timestamp, because an
  # imported account starts deactivated with no timestamp at all: the row is
  # the status, the timestamp is only "since when".
  defp status_scope(nil), do: RepoStore.list_users()
  defp status_scope("active"), do: Enum.filter(RepoStore.list_users(), & &1.active)

  defp status_scope("deactivated"),
    do: Enum.filter(RepoStore.list_users(), &(not &1.active))

  # A substring over each identifying column, case-insensitively; a nil
  # column (a handle under single) matches nothing.
  defp filter_grep(users, nil), do: users

  defp filter_grep(users, pattern) do
    needle = String.downcase(pattern)

    Enum.filter(users, fn user ->
      Enum.any?([user.did, user.handle, user.email], fn value ->
        value != nil and String.contains?(String.downcase(value), needle)
      end)
    end)
  end

  # Anything else is a typo, and a typo is usage, not an empty list that
  # reads as "no such accounts".
  defp check_status(nil), do: :ok
  defp check_status("active"), do: :ok
  defp check_status("deactivated"), do: :ok

  defp check_status(_other),
    do: {:usage, gettext("status must be active or deactivated") <> "\n\n" <> @usage}

  # Field labels below ("did", "repo rev", ...) are plain literals on
  # purpose: a label is a name, not a sentence, and a short msgid would
  # inherit a browser page's translation under the shared catalog. The prose
  # around them goes through gettext.
  defp print_show(user) do
    field("did", user.did)
    field("handle", user.handle || "-")
    field("email", user.email || "-")
    field("active", if(user.active, do: gettext("yes"), else: gettext("no")))
    field("deactivated at", stamp(user.deactivated_at))
    field("repo rev", RepoStore.repo_rev(user.did) || "-")

    case Accounts.list_app_passwords(user.did) do
      [] -> IO.puts(gettext("no app passwords"))
      rows -> Enum.each(rows, &print_app_password_row/1)
    end
  end

  # The dry run's whole answer, and the real run's before-picture: the same
  # lines, from the same read. What the summary promises is what the action
  # does, and the one line it promises beyond the rows is the caveat.
  defp print_deletion_summary(facts) do
    user = facts.user

    IO.puts(gettext("this permanently deletes the account and its repo; it cannot be undone"))
    field("did", user.did)
    field("handle", user.handle || "-")
    field("email", user.email || "-")
    field("active", if(user.active, do: gettext("yes"), else: gettext("no")))
    field("repo records", Integer.to_string(facts.record_count))
    field("repo blocks", Integer.to_string(facts.block_count))
    field("firehose events", Integer.to_string(facts.event_count))
    field("signing key", facts.key_path)
    field("rotation key", facts.rotation_key_path)
    field("blob directory", facts.blob_dir)
    IO.puts(gettext("firehose events already emitted survive this deletion"))
  end

  # The --json shapes for the read verbs. Field names are the storage
  # vocabulary and absence is null (never the dash the table prints), so a
  # script reads the same field both ways.
  defp user_json(user) do
    %{
      did: user.did,
      handle: user.handle,
      email: user.email,
      active: user.active,
      deactivated_at: stamp_json(user.deactivated_at)
    }
  end

  defp show_json(user) do
    user_json(user)
    |> Map.put(:repo_rev, RepoStore.repo_rev(user.did))
    |> Map.put(
      :app_passwords,
      user.did |> Accounts.list_app_passwords() |> Enum.map(&app_password_json/1)
    )
  end

  defp app_password_json(row) do
    %{
      name: row.name,
      privileged: row.privileged,
      inserted_at: DateTime.to_iso8601(row.inserted_at)
    }
  end

  defp stamp_json(nil), do: nil
  defp stamp_json(datetime), do: DateTime.to_iso8601(datetime)

  # The deletion goes through the protocol flow: token minted for the
  # account, password checked against it, only then do the rows go.
  defp delete(user) do
    with {:ok, password} <- Input.password("Account password: "),
         {:ok, %{token: token}} <- Accounts.request_account_delete(user) do
      case Accounts.delete_account(user, user.did, password, token) do
        {:ok, did} ->
          IO.puts("deleted #{did}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The table form of the app-passwords verb: the empty case is named in
  # prose, where the JSON form answers an empty array.
  defp print_app_passwords(user, rows) do
    if rows == [] do
      IO.puts("no app passwords for #{user.handle || user.did}")
    else
      Enum.each(rows, &print_app_password_row/1)
    end
  end

  # Shared by the app-passwords verb and show, so the two views of one thing
  # cannot drift apart. Names and privileges only; the passwords themselves
  # are unrecoverable by construction.
  defp print_app_password_row(row) do
    priv = if row.privileged, do: "privileged", else: "-"

    IO.puts(
      String.pad_trailing(row.name, 32) <>
        String.pad_trailing(priv, 12) <>
        DateTime.to_iso8601(row.inserted_at)
    )
  end

  # The label column both report shapes share: two spaces in, the label padded
  # past its longest neighbour, then the value.
  @field_width 17

  defp field(label, value), do: IO.puts("  " <> String.pad_trailing(label, @field_width) <> value)

  defp stamp(nil), do: "-"
  defp stamp(datetime), do: DateTime.to_iso8601(datetime)
end
