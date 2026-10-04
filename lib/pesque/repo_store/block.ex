defmodule Pesque.RepoStore.Block do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "blocks" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :data, :binary
    field :inserted_at, :utc_datetime
  end
end
