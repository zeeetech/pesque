defmodule Mix.Tasks.Pesque.CreateAccount do
  @shortdoc "Provisions a local account, the path taken when registration is closed."

  @moduledoc """
  Creates an account through Pesque.Accounts.create_account/3, the same
  function the HTTP endpoint calls, so there is one code path that creates an
  account rather than two that can drift.

      mix pesque.create_account --handle alice.example.com --email a@example.com --password secret123

  Runs with the endpoint not serving, so it works against a data directory the
  live server already has open instead of failing on the port.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    endpoint = Application.get_env(:pesque, PesqueWeb.Endpoint, [])

    Application.put_env(
      :pesque,
      PesqueWeb.Endpoint,
      Keyword.put(endpoint, :server, false)
    )

    Mix.Task.run("app.start")

    {opts, _args} =
      OptionParser.parse!(argv, strict: [handle: :string, email: :string, password: :string])

    handle = opts[:handle] || Mix.shell().prompt("handle")
    email = opts[:email] || Mix.shell().prompt("email")
    password = opts[:password] || Mix.shell().prompt("password")

    case Pesque.Accounts.create_account(handle, email, password) do
      {:ok, user} ->
        Mix.shell().info("created #{user.handle} (#{user.did})")

      {:error, reason} ->
        Mix.raise("could not create account: #{inspect(reason)}")
    end
  end
end
