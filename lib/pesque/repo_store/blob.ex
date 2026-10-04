defmodule Pesque.RepoStore.Blob do
  use Ecto.Schema

  @primary_key false
  schema "blobs" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :mime_type, :string
    field :size, :integer
    field :inserted_at, :utc_datetime
  end
end
