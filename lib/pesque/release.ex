defmodule Pesque.Release do
  @moduledoc "Release support: task bootstrap, the boot-time migration, and the account printer."

  @doc """
  Starts the application for a one-off release task.

  A release `eval` boots the VM but does not start the applications, so a task
  that reads the server identity or touches the database has to ask for them
  first. The endpoint stays down: a task runs against the data directory the
  live server already holds, and binding the port would fail.
  """
  def boot! do
    Application.put_env(:pesque, :serve, false)

    case Application.ensure_all_started(:pesque) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "the application could not start: #{inspect(reason)}"
    end
  end

  def migrate do
    if Process.whereis(Pesque.Repo) do
      run()
    else
      {:ok, _, _} = Ecto.Migrator.with_repo(Pesque.Repo, fn _repo -> run() end)
      :ok
    end
  end

  @doc "Turns an error reason into a sentence a person running a command can act on."
  def describe_error(reason) do
    case reason do
      {:old_pds_status, status, message} ->
        "the old PDS answered #{status}: #{message}"

      {:old_pds_status, status} ->
        "the old PDS answered #{status}"

      {:old_pds_unreachable, detail} ->
        "the old PDS could not be reached: #{inspect(detail)}"

      :plc_code_missing ->
        "no PLC code was read; run this where the prompt can be answered, or set MIGRATE_PLC_TOKEN"

      :too_large ->
        "a blob is larger than this server accepts (#{Pesque.blob_max_bytes()} bytes); raise blob_upload_limit"

      :handle_not_available ->
        "that handle is already taken, or it is not under this server's handle domain"

      :account_exists ->
        "this server already has an account; conformant_single serves exactly one"

      :password_too_short ->
        "the password must be at least 8 characters"

      :email_required ->
        "an email address is required"

      :email_taken ->
        "another account already uses that email"

      :disallowed_handle ->
        "that handle is not allowed on this server"

      :not_found ->
        "no account with that DID or handle on this server"

      :invalid_password ->
        "that is not this account's password"

      :account_not_updated ->
        "the account row could not be updated"

      :plc_token_failed ->
        "a plc operation token could not be issued"

      :not_a_plc_account ->
        "that account is not a did:plc identity, and only those move through the PLC"

      :no_input ->
        "nothing was read from the prompt; run this where the question can be answered, " <>
          "or pass the value by flag or environment"

      {:password_env_empty, name} ->
        "#{name} is not set in the environment, or it is empty"

      :doctor_failed ->
        "doctor found problems; fix the failures above and run it again"

      :no_crawler_configured ->
        "no relay is configured to ask; set crawler = https://bsky.network"

      {:missing_option, key} ->
        "the migration is missing #{key}; give it by flag or environment"

      {:unknown_env, names} ->
        "unknown PDS_ variables in the environment: " <>
          Enum.join(names, ", ") <>
          ". A variable the server reads is a config key uppercased with a PDS_ prefix " <>
          "(pesque.conf.example lists them all); the internal ones the tooling sets are " <>
          "PDS_CONFIG, PDS_PUBLIC_IP and PDS_TAG"

      {:unknown_key, key, line} ->
        "the config file names an unknown key #{inspect(key)} on line #{line}"

      {:duplicate_key, key, line} ->
        "the config file repeats #{inspect(key)} on line #{line}"

      {:invalid_line, line} ->
        "the config file has a line that is not a comment, blank, or key = value on line #{line}"

      {:missing_value, line} ->
        "the config file has a key with no value on line #{line}"

      {:unreadable, path, reason} ->
        "cannot read #{path}: #{inspect(reason)}"

      {:unwritable, path, reason} ->
        "cannot write #{path}: #{inspect(reason)}"

      {:missing_data_dir_entries, missing} ->
        "the data directory is missing " <>
          Enum.join(missing, ", ") <>
          "; " <>
          "a server that has never booted has nothing to back up"

      {:tar, reason} ->
        "could not write the archive: #{inspect(reason)}"

      {:sqlite, reason} ->
        "the database answered: #{inspect(reason)}"

      :locked ->
        "the database is locked; stop the server (the driver does this) and run restore again"

      {:bad_archive, :no_manifest} ->
        "the archive carries no manifest.json, so it is not a pesque backup"

      {:bad_archive, :manifest_not_json} ->
        "the archive's manifest.json does not decode, so it is not a pesque backup"

      {:bad_archive, :unknown_format} ->
        "the archive's manifest names another format, so it is not a pesque backup"

      {:bad_archive, reason} ->
        "the archive could not be read: #{inspect(reason)}"

      {:unsupported_backup_version, version} ->
        "the archive is backup version #{version}; this server writes and restores " <>
          "version 1, so upgrade pesque to restore it"

      {:missing_entry, name} ->
        "the archive is missing #{name}, so it is not a complete pesque backup"

      {:missing_staged, name} ->
        "the restore is missing its staged #{name}; the previous state is in the .old files"

      {:swap_failed, name, reason} ->
        "the restore could not move #{name}: #{inspect(reason)}; " <>
          "the previous state is in the .old files"

      other ->
        inspect(other)
    end
  end

  @doc """
  Prints the account and what to do next, the part of account creation the
  account verbs share.
  """
  def print_account(account) do
    IO.puts("")
    IO.puts("Account created.")
    IO.puts("  handle  #{account.handle}")
    IO.puts("  did     #{account.did}")
    IO.puts("")
    IO.puts("Point this domain at the server, then add the handle record, and give")
    IO.puts("DNS a few minutes to catch up:")
    IO.puts("")
    Enum.each(dns_lines(account), &IO.puts/1)
    IO.puts("")
    IO.puts("Check that everything is reachable from outside:")
    IO.puts("")
    IO.puts("  pesque doctor")
  end

  # A did:web account serves its own handle at /.well-known/atproto-did, so
  # only the host record is needed. A path_multi account is resolved at
  # _atproto.<handle>, which nothing else publishes, so the TXT carries the
  # DID the directory minted.
  defp dns_lines(%{did: "did:plc:" <> _} = account) do
    [host_line(), "  _atproto.#{account.handle}   TXT    \"did=#{account.did}\""]
  end

  defp dns_lines(_account), do: [host_line()]

  defp host_line do
    ip =
      case System.get_env("PDS_PUBLIC_IP") do
        nil -> "<this server's public IP>"
        "" -> "<this server's public IP>"
        value -> value
      end

    "  #{Pesque.hostname()}   A      #{ip}"
  end

  defp run do
    path = Path.join(:code.priv_dir(:pesque), "repo/migrations")
    Ecto.Migrator.run(Pesque.Repo, path, :up, all: true)
  end
end
