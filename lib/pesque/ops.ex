defmodule Pesque.Ops do
  @moduledoc "Host-side driver contract of record. Implementations live in cli/ (Zig). Exit codes: 0 ok, 1 domain failure, 2 usage; CLI adds 3 (driver/env)."

  defmodule RunOnce do
    @enforce_keys [:verb]
    defstruct verb: nil, argv: [], env: %{}, mounts: %{}, interactive?: false

    @type t :: %__MODULE__{
            verb: String.t(),
            argv: [String.t()],
            env: %{String.t() => String.t()},
            mounts: %{String.t() => String.t()},
            interactive?: boolean()
          }
  end

  @type primitive_error :: {:error, term()}

  @callback data_dir() :: {:ok, String.t() | {:volume, String.t()}} | primitive_error
  @callback run_once(RunOnce.t()) :: :ok | primitive_error
  @callback up() :: :ok | primitive_error
  @callback down() :: :ok | primitive_error
  @callback restart() :: :ok | primitive_error
  @callback pull(nil | String.t()) :: :ok | primitive_error
  @callback logs(keyword()) :: :ok | primitive_error
  @callback health() :: {:ok, :healthy | :degraded} | primitive_error
  @callback interactive?() :: boolean()
  @callback owns_lifecycle?() :: boolean()
end
