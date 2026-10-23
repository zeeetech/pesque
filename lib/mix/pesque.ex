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
  Like run/1, for a verb that reads the config and touches nothing else: an
  invalid config kills the boot before this could report it, so it runs with
  no boot at all.
  """
  def run_without_boot(verb_argv), do: dispatch(verb_argv)

  defp dispatch(verb_argv) do
    case Pesque.Cli.run(verb_argv) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("error: " <> Pesque.Cli.Explain.render(reason))

      {:usage, text} ->
        Mix.raise(text)
    end
  end
end
