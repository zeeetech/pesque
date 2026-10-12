defmodule Pesque.Cli.Input do
  @moduledoc """
  One input order for every verb, implemented here so they cannot drift: the
  flag, then the environment, then a prompt. Secrets never travel by argv:
  `--password-env` names the variable holding the password, so the value
  reaches a child process in its environment (invisible to `ps`).
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
  A password: `--password-env NAME`, then the conventional variable, then a
  no-echo prompt. A named variable that is unset or empty fails naming it:
  an empty pointed-at variable is a different failure from no password at all.
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
          {:ok, ""} -> {:error, {:password_env_empty, name}}
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
  # written first. The no-echo primitive needs a terminal (OTP 28 and up),
  # so a pipe falls back to an echoed read; a closed stdin answers
  # :no_input there, which is the refusal. A line that was read but cannot
  # become a string answers :no_input too: the echo fallback would read a
  # second line after the first was already consumed.
  defp no_echo_line(prompt) do
    case no_echo_read(prompt) do
      {:ok, value} -> {:ok, String.trim(value)}
      :fallback -> echo_line("")
      error -> error
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
        _ -> {:error, :no_input}
      catch
        _kind, _reason -> :fallback
      end
    else
      :fallback
    end
  end
end
