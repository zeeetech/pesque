defmodule Pesque.Cli.Explain do
  @moduledoc """
  The operator copy for a domain reason: what went wrong, and what to do next.

  Every reason the verbs answer maps to a `%{problem, next, detail}` map, and
  `render/1` flattens that map into the few lines the error path prints. The
  strings live in the `PesqueWeb.Gettext` catalog, so the CLI speaks the same
  language the pages do.

  Pure and total: a reason with no clause still renders. The fallback
  apologizes, asks for a report with `PESQUE_DEBUG=1`, and keeps the raw
  reason as its `detail`, so it stays debuggable without being the message.
  """

  use Gettext, backend: PesqueWeb.Gettext

  @doc """
  The structured message for a reason. `next` is nil when the problem needs no
  instruction; `detail` is nil except on the fallback, where it carries the
  raw reason.
  """
  def for_reason(reason)

  def for_reason({:old_pds_status, status, message}) do
    %{
      problem:
        gettext("the old PDS answered %{status}: %{message}",
          status: status,
          message: message
        ),
      next:
        gettext("check --old-pds; the old server has to stay up until the migration finishes"),
      detail: nil
    }
  end

  def for_reason({:old_pds_status, status}) do
    %{
      problem: gettext("the old PDS answered %{status}", status: status),
      next:
        gettext("check --old-pds; the old server has to stay up until the migration finishes"),
      detail: nil
    }
  end

  def for_reason({:old_pds_unreachable, detail}) do
    %{
      problem: gettext("the old PDS could not be reached: %{detail}", detail: inspect(detail)),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:plc_code_missing) do
    %{
      problem: gettext("no PLC code was read"),
      next: gettext("run this where the prompt can be answered, or set MIGRATE_PLC_TOKEN"),
      detail: nil
    }
  end

  def for_reason(:too_large) do
    %{
      problem:
        gettext("a blob is larger than this server accepts (%{bytes} bytes)",
          bytes: Pesque.blob_max_bytes()
        ),
      next: gettext("raise blob_upload_limit"),
      detail: nil
    }
  end

  def for_reason(:handle_not_available) do
    %{
      problem: gettext("that handle is already taken on this server"),
      next: gettext("choose another name, or see who has it with pesque account list"),
      detail: nil
    }
  end

  def for_reason(:handle_not_under_domain) do
    %{
      problem:
        gettext("that handle is not under this server's handle domain (%{domain})",
          domain: Pesque.handle_domain()
        ),
      next:
        gettext("under multi a handle looks like <name>.%{domain}",
          domain: Pesque.handle_domain()
        ),
      detail: nil
    }
  end

  def for_reason(:web_not_supported_under_multi) do
    %{
      problem: gettext("multi-user accounts are always did:plc; did:web needs single mode"),
      next:
        gettext(
          "omit --identity to mint a did:plc, or run mode = single to host a single did:web account"
        ),
      detail: nil
    }
  end

  def for_reason(:invalid_identity) do
    %{
      problem: gettext("that account DID method is not supported"),
      next: gettext("choose web or plc"),
      detail: nil
    }
  end

  def for_reason(:invalid_handle) do
    %{
      problem: gettext("that is not a valid handle"),
      next: gettext("a label takes letters, numbers and hyphen"),
      detail: nil
    }
  end

  def for_reason(:account_exists) do
    %{
      problem: gettext("this server already has an account; single mode serves exactly one"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:password_too_short) do
    %{
      problem: gettext("the password must be at least 8 characters"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:email_required) do
    %{
      problem: gettext("an email address is required"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:email_taken) do
    %{
      problem: gettext("another account already uses that email"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:disallowed_handle) do
    %{
      problem: gettext("that handle is not allowed on this server"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:not_found) do
    %{
      problem: gettext("no account with that DID or handle on this server"),
      next: gettext("list what exists with pesque account list"),
      detail: nil
    }
  end

  def for_reason(:invalid_password) do
    %{
      problem: gettext("that is not this account's password"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:account_not_updated) do
    %{
      problem: gettext("the account row could not be updated"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:token_failed) do
    %{
      problem: gettext("a single-use token could not be issued"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:not_a_plc_account) do
    %{
      problem:
        gettext("that account is not a did:plc identity, and only those move through the PLC"),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:no_input) do
    %{
      problem: gettext("nothing was read from the prompt"),
      next: gettext("run this from a terminal, or pipe the value on stdin"),
      detail: nil
    }
  end

  def for_reason(:doctor_failed) do
    %{
      problem: gettext("doctor found problems"),
      next: gettext("fix the failures above and run it again"),
      detail: nil
    }
  end

  def for_reason(:no_crawler_configured) do
    %{
      problem: gettext("no relay is configured to ask"),
      next: gettext("set crawler = https://bsky.network"),
      detail: nil
    }
  end

  def for_reason({:missing_option, key}) do
    %{
      problem: gettext("the migration is missing %{key}", key: key),
      next: gettext("give it by flag or environment"),
      detail: nil
    }
  end

  def for_reason({:unknown_env, names}) do
    %{
      problem:
        gettext("unknown PDS_ variables in the environment: %{names}",
          names: Enum.join(names, ", ")
        ),
      next:
        gettext(
          "a variable the server reads is a config key uppercased with a PDS_ prefix " <>
            "(pesque.conf.example lists them all); the internal ones the tooling sets are " <>
            "PDS_CONFIG, PDS_PUBLIC_IP and PDS_TAG"
        ),
      detail: nil
    }
  end

  def for_reason({:unknown_key, key, line}) do
    %{
      problem:
        gettext("the config file names an unknown key %{key} on line %{line}",
          key: inspect(key),
          line: line
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:duplicate_key, key, line}) do
    %{
      problem:
        gettext("the config file repeats %{key} on line %{line}",
          key: inspect(key),
          line: line
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:invalid_line, line}) do
    %{
      problem:
        gettext(
          "the config file has a line that is not a comment, blank, or key = value on line %{line}",
          line: line
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:missing_value, line}) do
    %{
      problem: gettext("the config file has a key with no value on line %{line}", line: line),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:unreadable, path, reason}) do
    %{
      problem: gettext("cannot read %{path}: %{reason}", path: path, reason: inspect(reason)),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:unwritable, path, reason}) do
    %{
      problem: gettext("cannot write %{path}: %{reason}", path: path, reason: inspect(reason)),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:missing_data_dir_entries, missing}) do
    %{
      problem:
        gettext(
          "the data directory is missing %{entries}; a server that has never booted has nothing to back up",
          entries: Enum.join(missing, ", ")
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:tar, reason}) do
    %{
      problem: gettext("could not write the archive: %{reason}", reason: inspect(reason)),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:sqlite, reason}) do
    %{
      problem: gettext("the database answered: %{reason}", reason: inspect(reason)),
      next: nil,
      detail: nil
    }
  end

  def for_reason(:locked) do
    %{
      problem: gettext("the database is locked"),
      next: gettext("stop the server (the driver does this) and run restore again"),
      detail: nil
    }
  end

  def for_reason({:bad_archive, :no_manifest}) do
    %{
      problem: gettext("the archive carries no manifest.json, so it is not a pesque backup"),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:bad_archive, :manifest_not_json}) do
    %{
      problem:
        gettext("the archive's manifest.json does not decode, so it is not a pesque backup"),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:bad_archive, :unknown_format}) do
    %{
      problem:
        gettext("the archive's manifest names another format, so it is not a pesque backup"),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:bad_archive, reason}) do
    %{
      problem: gettext("the archive could not be read: %{reason}", reason: inspect(reason)),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:unsupported_backup_version, version}) do
    %{
      problem:
        gettext(
          "the archive is backup version %{version}; this server writes and restores version 1",
          version: version
        ),
      next: gettext("upgrade pesque to restore it"),
      detail: nil
    }
  end

  def for_reason({:missing_entry, name}) do
    %{
      problem:
        gettext("the archive is missing %{name}, so it is not a complete pesque backup",
          name: name
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:missing_staged, name}) do
    %{
      problem:
        gettext(
          "the restore is missing its staged %{name}; the previous state is in the .old files",
          name: name
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason({:swap_failed, name, reason}) do
    %{
      problem:
        gettext(
          "the restore could not move %{name}: %{reason}; the previous state is in the .old files",
          name: name,
          reason: inspect(reason)
        ),
      next: nil,
      detail: nil
    }
  end

  def for_reason(other) do
    %{
      problem: gettext("could not complete the operation"),
      next: gettext("this looks like a defect. run it again with PESQUE_DEBUG=1 and report it"),
      detail: inspect(other)
    }
  end

  @doc """
  The lines the error path prints: the problem, then the next step and the
  detail, each on its own line indented by two spaces.
  """
  def render(reason) do
    explanation = for_reason(reason)

    [explanation.problem, explanation.next, explanation.detail]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n  ")
  end
end
