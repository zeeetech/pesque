defmodule Pesque.Cli.Input do
  @moduledoc """
  How verbs read their input (D3): the flag first, then the environment, then
  a prompt. Implemented once, here, so the verbs cannot drift on the order or
  on where secrets travel.

  Secrets never travel by argv: `--password-env` names the environment
  variable that holds the password, so the value reaches a child process in
  its environment (invisible to `ps`) rather than in its argument list, and
  what would otherwise be `--password VALUE` is a no-echo prompt or nothing.
  """

  @doc """
  Parses verb flags. An unknown flag is usage (exit 2), not a crash or a
  silently ignored typo, and so is a stray positional argument for a verb
  that takes none; `allow_positional` is for the one that does.
  """
  def options(argv, strict, usage, allow_positional \\ false) do
    case OptionParser.parse(argv, strict: strict) do
      {_opts, _args, invalid} when invalid != [] ->
        flags = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:usage, "unknown option: #{flags}\n\n" <> usage}

      {opts, args, _invalid} ->
        cond do
          args == [] or allow_positional -> {:ok, opts, args}
          true -> {:usage, "unexpected argument: #{hd(args)}\n\n" <> usage}
        end
    end
  end

  @doc """
  A plain value: the flag, then `env`, then an echoed prompt.

  The prompt is a seam (a 1-arity fun) so tests can watch the resolution
  order without a terminal.
  """
  def text(opts, flag, env, prompt \\ "value: ", prompt_fun \\ &echo_line/1) do
    with :no_value <- flag_or_env(opts, flag, env) do
      prompt_fun.(prompt)
    end
  end

  @doc """
  A password: `--password-env NAME` (the NAME of an environment variable
  holding it), then the conventional environment variable, then a no-echo
  prompt. A named variable that is unset or empty fails naming it, because
  "the variable you pointed me at is empty" is a different problem from "no
  password was given".
  """
  def password(opts, env, prompt \\ "password: ", prompt_fun \\ &no_echo_line/1) do
    with :no_value <- password_env(opts),
         :no_value <- env_value(env) do
      prompt_fun.(prompt)
    end
  end

  defp flag_or_env(opts, flag, env) do
    case Keyword.get(opts, flag) do
      nil -> env_value(env)
      value -> {:ok, value}
    end
  end

  defp password_env(opts) do
    case Keyword.get(opts, :password_env) do
      nil ->
        :no_value

      name ->
        case env_value(name) do
          {:ok, value} -> {:ok, value}
          :no_value -> {:error, {:password_env_empty, name}}
        end
    end
  end

  defp env_value(name) do
    case System.get_env(name) do
      nil -> :no_value
      value -> {:ok, value}
    end
  end

  # An echoed read for values that are not secrets. :eof is what a closed
  # stdin answers: refuse rather than pretend nothing was asked.
  defp echo_line(prompt) do
    case IO.gets(prompt) do
      :eof -> {:error, :no_input}
      line -> {:ok, String.trim(line)}
    end
  end

  # :io.get_password/0 takes an io device, not a prompt, so the prompt is
  # written first and the read asks the group leader. The no-echo primitive
  # is OTP 28 and up and needs a terminal, so an older runtime or a pipe
  # falls back to an echoed read rather than failing; a closed stdin
  # answers :no_input there, which is the refusal.
  defp no_echo_line(prompt) do
    case no_echo_read(prompt) do
      {:ok, value} -> {:ok, String.trim(value)}
      :fallback -> echo_line("")
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
