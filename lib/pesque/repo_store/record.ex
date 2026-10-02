defmodule Pesque.RepoStore.Record do
  use Ecto.Schema

  @primary_key false
  schema "records" do
    field :did, :string, primary_key: true
    field :collection, :string, primary_key: true
    field :rkey, :string, primary_key: true
    field :cid, :string
    field :data, :binary
    field :inserted_at, :utc_datetime
  end
end
