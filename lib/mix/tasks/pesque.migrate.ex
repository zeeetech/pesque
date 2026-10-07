defmodule Mix.Tasks.Pesque.Migrate do
  @shortdoc "Moves an existing ATProto account onto this server."

  @moduledoc """
  Moves an existing ATProto account (for example a did:plc account on
  bsky.social) onto this server, automating the scriptable half of
  docs/guides/migration.md.

      mix pesque.migrate --old-pds https://bsky.social --handle alice.example.com \
        --email alice@example.com --password-env PESQUE_PASSWORD

  Options:

    * `--old-pds` - base URL of the PDS the account currently lives on.
    * `--handle` - the account's handle, which keeps resolving to the same DID.
    * `--email` - the email for the new account.
    * `--password` - the old PDS password (or app password), reused as the new
      account's password. Lands in your shell history and `ps`, so prefer
      `--password-env`.
    * `--password-env` - the name of an environment variable holding the
      password.

  Password resolution order: `--password`, then `--password-env`, then a
  no-echo prompt.

  The move stops at the identity step. This server does not implement
  `signPlcOperation`, so the old PDS signs the operation carrying the
  recommended credentials; on bsky.social that needs a code emailed to the
  account holder, which this task prompts for. Once the operation lands the
  move is one-way.

  Runs with the endpoint not serving, so it works against a data directory the
  live server already has open instead of failing on the port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    # No endpoint: this task writes rows, keys and blobs, it never answers a
    # request, so it does not stand one up.
    Application.put_env(:pesque, :serve, false)

    Mix.Task.run("app.start")

    {opts, _args} =
      OptionParser.parse!(argv,
        strict: [
          old_pds: :string,
          handle: :string,
          email: :string,
          password: :string,
          password_env: :string
        ]
      )

    old_pds = opts[:old_pds] || Mix.shell().prompt("old pds")
    handle = opts[:handle] || Mix.shell().prompt("handle")
    email = opts[:email] || Mix.shell().prompt("email")
    password = password(opts)

    case Pesque.Migrate.run(
           old_pds: old_pds,
           handle: handle,
           email: email,
           password: password
         ) do
      :ok ->
        Mix.shell().info("moved #{handle} onto this server")

      {:error, reason} ->
        Mix.raise("could not migrate the account: #{inspect(reason)}")
    end
  end

  defp password(opts) do
    cond do
      opts[:password] ->
        opts[:password]

      opts[:password_env] ->
        case System.get_env(opts[:password_env]) do
          nil -> Mix.raise("#{opts[:password_env]} is not set in the environment")
          "" -> Mix.raise("#{opts[:password_env]} is empty")
          value -> value
        end

      true ->
        read_password()
    end
  end

  # :io.get_password/1 takes an io device, not a prompt, so the prompt is
  # written first and the read asks the group leader. The no-echo primitive is
  # OTP 28 and up and needs a terminal, so an older runtime or a non-terminal
  # stdin falls back to an echoed prompt rather than failing.
  defp read_password do
    case no_echo_read("password: ") do
      {:ok, value} -> String.trim(value)
      :fallback -> read_line()
    end
  end

  # The prompt was already written; read a line without printing another.
  defp read_line do
    case IO.gets("") do
      :eof -> Mix.raise("no password was read")
      line -> String.trim(line)
    end
  end

  defp no_echo_read(prompt) do
    if function_exported?(:io, :get_password, 0) do
      IO.write(prompt)

      try do
        case :io.get_password() do
          answer when is_list(answer) or is_binary(answer) -> {:ok, to_string(answer)}
          _no_data -> :fallback
        end
      rescue
        _ -> :fallback
      catch
        _kind, _reason -> :fallback
      end
    else
      :fallback
    end
  end
end
