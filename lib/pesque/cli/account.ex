defmodule Pesque.Cli.Account do
  @moduledoc """
  The account verbs, wired straight to the domain: create, list, delete,
  takedown, activate and reset-password.
  """

  alias Pesque.Accounts
  alias Pesque.Accounts.User
  alias Pesque.Cli.Input
  alias Pesque.Release
  alias Pesque.RepoStore

  @usage """
  usage: pesque account <subcommand> [flags]

    create --handle H --email E [--password-env VAR]
    list
    delete --did D | --handle H
    takedown --did D | --handle H
    activate --did D | --handle H
    reset-password --did D | --handle H

  Input order is the flag, then the conventional environment
  (ACCOUNT_HANDLE, ACCOUNT_EMAIL, ACCOUNT_PASSWORD), then a prompt.
  """

  # --did and --handle name the same account.
  @identifier_switches [did: :string, handle: :string]
  @password_switches [password_env: :string]

  def run(["create" | argv]) do
    with {:ok, opts, []} <-
           Input.options(argv, [handle: :string, email: :string] ++ @password_switches, @usage),
         {:ok, handle} <- Input.text(opts, :handle, "ACCOUNT_HANDLE", "handle: "),
         {:ok, email} <- Input.text(opts, :email, "ACCOUNT_EMAIL", "email: "),
         {:ok, password} <- Input.password(opts, "ACCOUNT_PASSWORD"),
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
           Input.options(argv, @identifier_switches ++ @password_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         {:ok, password} <- Input.password(opts, "ACCOUNT_PASSWORD"),
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
           Input.options(argv, @identifier_switches ++ @password_switches, @usage),
         {:ok, identifier} <- identifier(opts),
         {:ok, password} <- Input.password(opts, "ACCOUNT_PASSWORD", "new password: "),
         :ok <- Release.boot!(),
         {:ok, user} <- resolve(identifier),
         :ok <- Accounts.reset_password(user, password) do
      IO.puts("password updated for #{user.handle || user.did}; every session it held is revoked")
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
