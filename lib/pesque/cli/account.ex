defmodule Pesque.Cli.Account do
  @moduledoc """
  The account verbs, wired straight to the domain: create, list, delete,
  takedown, activate, reset-password, plc-token and the app-password verbs.
  """

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Cli.Input
  alias Pesque.Plc
  alias Pesque.Release
  alias Pesque.RepoStore

  @usage """
  usage: pesque account <subcommand> [flags]

    create --handle H --email E
    list
    delete --did D | --handle H
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
  """

  # --did and --handle name the same account.
  @identifier_switches [did: :string, handle: :string]

  def run(["create" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, [handle: :string, email: :string], @usage),
         {:ok, handle} <- Input.text(opts, :handle, "ACCOUNT_HANDLE", "handle: "),
         {:ok, email} <- Input.text(opts, :email, "ACCOUNT_EMAIL", "email: "),
         {:ok, password} <-
           Input.password("Password for the new account (at least 8 characters): "),
         :ok <- Release.boot!() do
      case Accounts.create_account(handle, email, password) do
        {:ok, account} ->
          Release.print_account(account)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(["list" | argv]) do
    with {:ok, _opts, []} <- Input.options(argv, [], @usage),
         :ok <- Release.boot!() do
      IO.puts(header())

      Enum.each(RepoStore.list_users(), &print_row/1)
      :ok
    end
  end

  def run(["delete" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         {:ok, password} <- Input.password("Account password: "),
         :ok <- Release.boot!(),
         {:ok, user} <- resolve(identifier) do
      # The deletion goes through the protocol flow: token minted for the
      # account, password checked against it, only then do the rows go.
      case Accounts.request_account_delete(user) do
        {:ok, %{token: token}} ->
          case Accounts.delete_account(user, user.did, password, token) do
            {:ok, did} ->
              IO.puts("deleted #{did}")
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def run(["takedown" | argv]) do
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
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
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
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
           Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         {:ok, password} <- Input.password("new password: "),
         :ok <- Release.boot!(),
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
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
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
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
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
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
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
    with {:ok, opts, []} <- Input.options(argv, @identifier_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         :ok <- Release.boot!(),
         {:ok, user} <- resolve(identifier) do
      rows = Accounts.list_app_passwords(user.did)

      if rows == [] do
        IO.puts("no app passwords for #{user.handle || user.did}")
      else
        Enum.each(rows, fn row ->
          priv = if row.privileged, do: "privileged", else: "-"

          IO.puts(
            String.pad_trailing(row.name, 32) <>
              String.pad_trailing(priv, 12) <>
              DateTime.to_iso8601(row.inserted_at)
          )
        end)
      end

      :ok
    end
  end

  def run(["revoke-app-password" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, @identifier_switches ++ [name: :string], @usage),
         {:ok, identifier} <- identifier(opts),
         {:ok, name} <- Input.text(opts, :name, "APP_PASSWORD_NAME", "name: "),
         :ok <- Release.boot!(),
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
end
