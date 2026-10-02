defmodule Pesque.RepoStore.Event do
  use Ecto.Schema

  @primary_key {:seq, :integer, []}
  schema "events" do
    field :did, :string
    field :payload, :binary
    field :inserted_at, :utc_datetime
  end
end
