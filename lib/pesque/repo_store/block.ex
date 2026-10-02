defmodule Pesque.RepoStore.Block do
  use Ecto.Schema

  @primary_key false
  schema "blocks" do
    field :cid, :string, primary_key: true
    field :did, :string
    field :data, :binary
    field :inserted_at, :utc_datetime
  end
end
