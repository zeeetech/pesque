defmodule Pesque.Migrate.Job do
  @moduledoc """
  A move that runs off-request, and the row a page watches.

  The row carries no credential: the old account's password never leaves the
  worker process, and the PLC code is handed to that process directly rather
  than written down. What a row knows is what anyone holding the token may
  know, and no more.

  The token is the whole capability. The browser surface has no session, so
  the URL a person holds is the only thing between a stranger and the state
  of a move; the unique index on it is what makes a token name exactly one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "migration_jobs" do
    field :token, :string
    field :handle, :string
    field :old_pds, :string
    field :phase, Ecto.Enum, values: [:running, :awaiting_code, :done, :failed], default: :running
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:token, :handle, :old_pds, :phase, :error])
    |> validate_required([:token, :handle, :old_pds])
    |> unique_constraint(:token)
  end

  # A phase moves without a cast, because the caller is the runner and not a
  # form: what it writes is one of the four the enum knows, and an error
  # string the copy already has a sentence for.
  def phase_changeset(%__MODULE__{} = job, phase, error \\ nil) do
    change(job, phase: phase, error: error)
  end
end
