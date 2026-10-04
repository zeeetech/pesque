defmodule Pesque.RepoStore.Meta do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:key, :string, []}
  schema "meta" do
    field :value, :string
  end
end
