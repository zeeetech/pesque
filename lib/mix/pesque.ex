defmodule Mix.Pesque do
  @moduledoc """
  Shared plumbing for the pesque.* mix tasks: boot the application with the
  endpoint down, then run the same verb the release runs. The release carries
  no Mix, so `bin/pesque <verb>` is the real surface and the tasks are the
  dev-mode spelling of it, dispatched through `Pesque.Cli.run/1`.
  """

  @doc "Boots without the endpoint and runs `Pesque.Cli.run/1` on `verb_argv`."
  def run(verb_argv) do
    Mix.Task.run("app.config")

    # No endpoint: a verb writes rows and reads files, it never answers a
    # request, so it does not stand one up.
    Application.put_env(:pesque, :serve, false)

    Mix.Task.run("app.start")

    dispatch(verb_argv)
  end

  @doc """
  Like run/1, for a verb whose password input the task resolves.

  `--password VALUE` is the mix task's dev convenience; the release CLI has
  no such flag. The value never reaches the verb layer as an argument: it is
  set as `env`, the conventional environment variable the verb's input
  resolution already reads, and the dispatched argv carries no flag and no
  value.
  """
  def run_with_password(verb_argv, env) do
    {password, verb_argv} = split_password(verb_argv)

    case password do
      nil ->
        run(verb_argv)

      value ->
        previous = System.get_env(env)
        System.put_env(env, value)

        try do
          run(verb_argv)
        after
          restore_env(env, previous)
        end
    end
  end

  @doc """
  Splits `--password VALUE` (or `--password=VALUE`) out of a task's argv,
  answering the value and the argv handed to `Pesque.Cli.run/1`.

  `--password-env` comes out too when a value was lifted: the password flag
  outranks it (flag, then named variable, then prompt), and a left-behind
  `--password-env` would flip that order. Without the flag the argv passes
  through untouched.
  """
  def split_password(argv) do
    case lift(argv, []) do
      {nil, argv} -> {nil, argv}
      {value, argv} -> {value, drop_password_env(argv)}
    end
  end

  @doc """
  Like run/1, for a verb that reads the config and touches nothing else: an
  invalid config kills the boot before this could report it, so it runs with
  no boot at all.
  """
  def run_without_boot(verb_argv), do: dispatch(verb_argv)

  defp lift([], acc), do: {nil, Enum.reverse(acc)}
  defp lift(["--password", value | rest], acc), do: {value, Enum.reverse(acc) ++ rest}
  defp lift(["--password=" <> value | rest], acc), do: {value, Enum.reverse(acc) ++ rest}
  defp lift([arg | rest], acc), do: lift(rest, [arg | acc])

  defp drop_password_env(argv), do: drop(argv, [])

  defp drop([], acc), do: Enum.reverse(acc)
  defp drop(["--password-env", _name | rest], acc), do: drop(rest, acc)
  defp drop(["--password-env=" <> _name | rest], acc), do: drop(rest, acc)
  defp drop([arg | rest], acc), do: drop(rest, [arg | acc])

  defp restore_env(env, nil), do: System.delete_env(env)
  defp restore_env(env, previous), do: System.put_env(env, previous)

  defp dispatch(verb_argv) do
    case Pesque.Cli.run(verb_argv) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("error: " <> Pesque.Release.describe_error(reason))

      {:usage, text} ->
        Mix.raise(text)
    end
  end
end
