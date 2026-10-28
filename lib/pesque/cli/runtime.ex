defmodule Pesque.Cli.Runtime do
  @moduledoc """
  Starts the application for an operator verb.

  The endpoint stays down and startup-only recovery, retention and relay work
  are skipped, so a one-off can run against a data directory a live server
  already holds. The configuration and the installation are not touched: the
  provider installed the former, and preparation owns the latter.
  """

  @doc "Starts Pesque for an operator verb. Returns a tagged error, never raises."
  def start do
    Application.put_env(:pesque, :serve, false)
    Application.put_env(:pesque, :operator_boot, true)

    case Application.ensure_all_started(:pesque) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:boot_failed, reason}}
    end
  end
end
