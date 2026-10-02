defmodule Pesque.RepoStore.Meta do
  use Ecto.Schema

  @primary_key {:key, :string, []}
  schema "meta" do
    field :value, :string
  end
end
