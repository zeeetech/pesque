defmodule PesqueWeb.Xrpc.HealthController do
  @moduledoc """
  Answers whether this server can actually do its job.

  The endpoint being reachable proves a process is listening, which is not the
  same thing. The probe runs against the users table rather than a bare
  SELECT 1, because a bare SELECT 1 succeeds against a database that has never
  been migrated, and a server that cannot read a single account is not healthy
  however promptly it answers.

  _health is unauthenticated, so the reason a check failed is logged rather
  than returned. Handing an anonymous caller the driver's error text tells
  them the driver, the table names and the shape of the failure, which is more
  than they need to know the server is down.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pesque.Repo

  require Logger

  def show(conn, _params) do
    case probe() do
      :ok ->
        json(conn, %{
          "status" => "ok",
          "version" => Pesque.version(),
          "checks" => %{"database" => "ok"}
        })

      {:error, reason} ->
        Logger.error("health check failed", reason: inspect(reason))

        conn
        |> put_status(503)
        |> json(%{
          "status" => "error",
          "version" => Pesque.version(),
          "checks" => %{"database" => "error"}
        })
    end
  end

  defp probe do
    case Ecto.Adapters.SQL.query(Repo, "SELECT did FROM users LIMIT 1", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
