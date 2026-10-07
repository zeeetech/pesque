defmodule Pesque.Preferences.Preference do
  @moduledoc "One account's private preferences, stored as a JSON array."

  use Ecto.Schema
  import Ecto.Changeset

  schema "preferences" do
    field :did, :string
    field :preferences, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:did, :preferences, :updated_at])
    |> validate_required([:did, :preferences])
    |> unique_constraint(:did)
  end
end
